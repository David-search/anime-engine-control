---
description: Recover a build-farm node — restart dead daemons, or deep-clean a disk-full node
argument-hint: <node 2..7> [restart|clean]   (default restart)
---

Self-heal a single build node. `restart` (default) recreates any of the 3 tmux
supervisors (`nzbget` / `trd` / `farm`) that died — the cron watchdog does this
every 2 min anyway, this just does it now. `clean` is for a node whose disk
filled (heavy AV1/BD pack stuck not shipping): it kills nzbget, clears the lock,
**wipes the node's working dirs** (`nzbget/{completed,inter,tmp,queue}`,
`staging`, `library`) and restarts. **`clean` is safe** — offshore + `done_node.jsonl`
are untouched, so already-shipped episodes stay and any unshipped item just
re-downloads. Detail: [self-hosted/RUNBOOK.md](../../self-hosted/RUNBOOK.md) §5/§7.

```bash
set -a && source .env && set +a
read -r N ACTION <<< "$ARGUMENTS"
[ -z "$N" ] && { echo "usage: /farm-fix <node 2..7> [restart|clean]"; exit 1; }
case "$N" in 2|3|4|5|6|7) ;; *) echo "node must be 2..7 (got '$N')"; exit 1 ;; esac
ACTION="${ACTION:-restart}"
H="vast-canada-$N"

case "$ACTION" in
  restart)
    ssh -o ConnectTimeout=10 "$H" 'bash -s' <<'EOS'
tmux has-session -t nzbget 2>/dev/null || tmux new-session -d -s nzbget "bash /data/nzbget_supervisor.sh"
tmux has-session -t trd 2>/dev/null    || tmux new-session -d -s trd 'while true; do pgrep -x transmission-da >/dev/null || transmission-daemon --download-dir /data/library; sleep 10; done'
tmux has-session -t farm 2>/dev/null   || tmux new-session -d -s farm "bash /data/run_node.sh >>/data/run_node.log 2>&1"
sleep 2
echo "sessions: $(tmux ls 2>/dev/null | cut -d: -f1 | tr '\n' ' ')"
echo "nzbget=$(ps -C nzbget --no-headers|wc -l) farm=$(pgrep -fc '[n]zb_farm.py') trd=$(pidof transmission-daemon|wc -w) free=$(df -h /data|tail -1|awk '{print $4}')"
EOS
    ;;
  clean)
    echo ">>> deep-clean canada-$N working dirs (offshore + done_node untouched; unshipped items re-download)"
    ssh -o ConnectTimeout=10 "$H" 'bash -s' <<'EOS'
tmux kill-session -t nzbget 2>/dev/null; pkill -9 -x nzbget 2>/dev/null; sleep 1
rm -f /data/nzbget/nzbget.lock
rm -rf /data/nzbget/completed/* /data/nzbget/inter/* /data/nzbget/tmp/* /data/nzbget/queue/* /data/staging/* /data/library/* 2>/dev/null
transmission-remote -t all --remove-and-delete 2>/dev/null || true
tmux new-session -d -s nzbget "bash /data/nzbget_supervisor.sh"
sleep 2
echo "cleaned. nzbget=$(ps -C nzbget --no-headers|wc -l) free=$(df -h /data|tail -1|awk '{print $4}')"
EOS
    ;;
  *) echo "unknown action: $ACTION (restart|clean)"; exit 1 ;;
esac
```

The farm loop (`run_node.sh`) retries forever and the cron watchdog (`ensure_up.sh`)
recreates sessions on reboot, so `restart` is rarely needed by hand — reach for it
when `/farm-status` shows a node stuck at `farm=0`. After `clean`, the farm session
keeps running and re-processes from `done_node.jsonl`, so it resumes where it left off.
