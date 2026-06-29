---
description: Provision a fresh vast.ai GPU instance as a build node — NVENC-gate first, then push the bundle
argument-hint: <ssh-alias>  e.g. vast-canada-4   (must already be in ~/.ssh/config)
---

Brings a **new/replacement** build node online. Step 1 is the **NVENC pre-test
gate** — the single most important check (a GPU that can't NVENC-encode wastes the
whole setup; see [[buildfarm-nvenc-provisioning]]). If it passes, this installs deps
and ships the build-farm bundle. The per-account `nzbget.conf`, the node's
`todo_node.jsonl`, the 3 tmux sessions, cron, and the offshore ssh key are the
**remaining manual steps** printed at the end — full procedure in
[self-hosted/RUNBOOK.md](../../self-hosted/RUNBOOK.md) §5.

```bash
set -a && source .env && set +a
H="${ARGUMENTS}"
[ -z "$H" ] && { echo "usage: /farm-provision <ssh-alias>  (e.g. vast-canada-4)"; exit 1; }

echo "=== 1. NVENC pre-test on $H (gate) ==="
NVOUT=$(ssh -o ConnectTimeout=12 "$H" \
  'ffmpeg -hide_banner -loglevel error -f lavfi -i testsrc2=size=640x360:rate=10 -t1 -c:v h264_nvenc -f null - 2>&1' \
  2>/dev/null)
if [ -n "$NVOUT" ]; then
  echo "  ✗ NVENC FAILED — do NOT provision this instance:"; echo "$NVOUT" | sed 's/^/    /'
  echo "  (Blackwell needs driver 590+/API13.1; driver 595.58.03 is broken; some vGPUs have NVENC disabled.)"
  exit 1
fi
echo "  ✓ NVENC OK (empty output = encoder works)"

echo "=== 2. install deps ==="
ssh "$H" 'export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && \
  apt-get install -y -qq nzbget transmission-daemon par2 unrar p7zip-full tmux rsync python3-pip cron ffmpeg >/dev/null 2>&1; \
  pip3 install -q requests 2>/dev/null; mkdir -p /data/nzbget/{completed,inter,queue,tmp,nzb,scripts} /data/library /data/staging; \
  echo "  deps installed; /data scaffold ready"'

echo "=== 3. push build-farm bundle (scripts only — NOT .env/creds) ==="
scp -q self-hosted/{dump_resolver,nzb_farm,nzb_acquire,ingest,hls_build,partition,pre_resolve}.py \
       self-hosted/{run_node,nzbget_supervisor,ensure_up}.sh \
       "$H":/data/ && echo "  ✓ bundle copied to $H:/data/"

cat <<EOF

=== REMAINING MANUAL STEPS (see RUNBOOK §5) ===
  a. nzbget.conf  → set Server1.{Username,Password} to the right EWEKA<n>_* for this
     node's account (2 nodes/account!), Connections=8, DupeCheck=no. scp to /data/nzbget.conf
  b. callback.env → CALLBACK_URL=$BACKEND_URL/api/watch, SELFHOST_INGEST_TOKEN=\$SELFHOST_INGEST_TOKEN
  c. todo        → scp this node's partition to /data/todo_node.jsonl
  d. re-seed done → ssh offshore 'find /srv/hls -name master.m3u8' | sed -E \\
       's#/srv/hls/([0-9]+)/([0-9]+)/sub/master.m3u8#{"aid": \1, "ep": \2, "dub": false}#' > done_node.jsonl ; scp to /data/
  e. offshore key → ssh $H 'cat /root/.ssh/id_ed25519.pub' >> offshore:/root/.ssh/authorized_keys
  f. start        → /farm-fix ${H#vast-canada-} restart   (creates the 3 tmux sessions)
  g. cron         → ssh $H '(crontab -l 2>/dev/null; echo "*/2 * * * * /data/ensure_up.sh"; echo "@reboot sleep 30 && /data/ensure_up.sh") | crontab -'
EOF
```

Always run this against the **ssh alias** (so `~/.ssh/config` resolves host+port);
add the new node to `.env` (`NODE_CANADA<n>`) and `~/.ssh/config` first. Remember the
Eweka **2-nodes-per-account** rule — picking the wrong account's creds trips the
"too many connections / 2 source IPs" limit for that account's other node.
