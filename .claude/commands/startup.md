---
description: Session startup check — git updates, app health, the 6-node build farm, offshore, fill progress
---

Run this at the start of a session (or anytime) to orient: pulls the latest state of
git, the live app, the build farm, and the fill. Read [STATE.md](../../STATE.md) alongside
it for what's deployed + what's pending. Read-only except `git fetch`.

```bash
set -a && source .env && set +a

echo "════════ 1. GIT — is anything behind origin? ════════"
git fetch origin --quiet 2>/dev/null
echo "control (anime-engine-control): $(git rev-list --left-right --count origin/main...HEAD 2>/dev/null | awk '{print "behind "$1" / ahead "$2}')  $([ -n "$(git status --porcelain)" ] && echo '(uncommitted changes!)')"
for svc in backend frontend; do
  d="work/$svc"
  if [ -d "$d/.git" ]; then
    git -C "$d" fetch origin --quiet 2>/dev/null
    echo "work/$svc: $(git -C "$d" rev-list --left-right --count origin/main...HEAD 2>/dev/null | awk '{print "behind "$1" / ahead "$2}')  $([ -n "$(git -C "$d" status --porcelain)" ] && echo '(uncommitted!)')"
  else echo "work/$svc: not cloned (/work-on $svc)"; fi
done

echo; echo "════════ 2. APP — is anichan.net live + self-host serving? ════════"
echo -n "  https://anichan.net/                 -> "; curl -sS -o /dev/null -w '%{http_code}\n' -m 12 https://anichan.net/ 2>&1
echo -n "  https://anichan.net/api/catalog/trending -> "; curl -sS -o /dev/null -w '%{http_code}\n' -m 12 https://anichan.net/api/catalog/trending 2>&1
echo -n "  ★ self-host source (cdn-direct?)     -> "; curl -sS -m 12 "https://anichan.net/api/watch/servers?anilistId=6&ep=12" 2>/dev/null | python3 -c "import json,sys;s=json.load(sys.stdin)['servers'][0];print(s['label'],'|', 'CDN' if 'cdn.anichan.net' in str(s.get('subtitles')) else 'proxy')" 2>&1

echo; echo "════════ 3. BUILD FARM — 6 nodes (free disk / daemons / shipped) ════════"
for N in 2 3 4 5 6 7; do
  ssh -o ClearAllForwardings=yes -o ControlPath=none -o ConnectTimeout=10 -o BatchMode=yes "vast-canada-$N" \
    'echo "  canada-'"$N"': free=$(df -h /data 2>/dev/null|tail -1|awk "{print \$4}") nzbget=$(ps -C nzbget --no-headers|wc -l) farm=$(pgrep -fc "[n]zb_farm.py") done=$(wc -l </data/done_node.jsonl 2>/dev/null||echo 0)"' \
    2>/dev/null || echo "  canada-$N: UNREACHABLE (instance rotated? check ~/.ssh/config + NODE_CANADA$N in .env)"
done

echo; echo "════════ 4. OFFSHORE + coverage ════════"
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes root@185.255.120.59 \
  'echo "  offshore: eps=$(find /srv/hls -name master.m3u8 2>/dev/null|wc -l) anime=$(ls /srv/hls 2>/dev/null|wc -l) used=$(du -sh /srv/hls 2>/dev/null|cut -f1) free=$(df -h /srv|tail -1|awk "{print \$4}")  (STOP farms if <1.5T; 16T cap)"' 2>/dev/null || echo "  offshore: UNREACHABLE"
ssh -o ConnectTimeout=10 -o BatchMode=yes vast-canada-2 \
  'echo "  selfhost_cache: $(docker exec anime-backend python3 -c "import os,pymongo;print(pymongo.MongoClient(os.environ[\"MONGO_URI\"])[\"anime_db\"].selfhost_cache.count_documents({}))" 2>/dev/null) anime cached"' 2>/dev/null

echo; echo "Now read STATE.md for what's deployed + the PENDING list (offshore backup, Cloudflare, etc.)."
```

If a build node is `UNREACHABLE`, the vast instance likely rotated — reconcile
`~/.ssh/config` + the `NODE_CANADA*` value in `.env`. For per-node accumulation/cleans use
`/farm-status` and `/farm-fix`. The PENDING items in STATE.md are **waiting on the user** —
don't action them unprompted.
