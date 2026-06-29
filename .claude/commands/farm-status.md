---
description: Sweep the 6-node self-host build farm + offshore origin (read-only health)
---

Read-only status of the whole self-host pipeline: each build node's daemons
(nzbget / farm loop / transmission), shipped-episode count, free disk, and
live-recoveries; then the offshore origin (episodes served + disk) and the
Mongo coverage-mark count. Full ops detail: [self-hosted/RUNBOOK.md](../../self-hosted/RUNBOOK.md).

```bash
set -a && source .env && set +a

echo "=== build farm (6 nodes: canada-2..7) ==="
for N in 2 3 4 5 6 7; do
  ssh -o ConnectTimeout=8 -o BatchMode=yes "vast-canada-$N" \
    'echo "canada-'"$N"': nzbget=$(ps -C nzbget --no-headers|wc -l) \
farm=$(pgrep -fc "[n]zb_farm.py") trd=$(pidof transmission-daemon|wc -w) \
done=$(wc -l </data/done_node.jsonl 2>/dev/null||echo 0) \
free=$(df -h /data 2>/dev/null|tail -1|awk "{print \$4}") \
live=$(grep -ciE "\[LIVE (single|pack)\]" /data/run_node.log 2>/dev/null||echo 0)"' \
    2>/dev/null || echo "canada-$N: UNREACHABLE (instance may have rotated — check ~/.ssh/config + NODE_CANADA$N in .env)"
done

echo; echo "=== offshore HLS origin (185.255.120.59) ==="
ssh -o ConnectTimeout=8 offshore \
  'printf "episodes=%s\n" "$(find /srv/hls -name master.m3u8 2>/dev/null|wc -l)"; du -sh /srv/hls 2>/dev/null; df -h /srv 2>/dev/null|tail -1' \
  2>/dev/null || echo "offshore: UNREACHABLE"

echo; echo "=== mongo selfhost_cache (catalog coverage marks) ==="
ssh -o ConnectTimeout=8 vast-canada-2 \
  'docker exec anime-backend python3 -c "import os,pymongo;print(pymongo.MongoClient(os.environ[\"MONGO_URI\"])[\"anime_db\"].selfhost_cache.count_documents({}))"' \
  2>/dev/null || echo "  (count unavailable)"
```

A healthy node shows `nzbget=1 farm=1 trd=1` and `free` well above ~40 G. `free`
creeping low or `farm=0` that keeps recurring → `/farm-fix <node>`. `UNREACHABLE`
usually means the vast instance was killed/rotated — reconcile `~/.ssh/config`
and the `NODE_CANADA*` value in `.env`.
