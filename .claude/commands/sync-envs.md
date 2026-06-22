---
description: Re-pull each service's .env from the AniChan server (source of truth) into work/<service>/.env
---

The AniChan server holds the canonical `.env` for each service at
`/home/anime/<service>/.env` — that file is the source of truth for
runtime config (the local `work/<service>/.env` is only a mirror).
`/work-on` and `/setup-all` fetch it once at clone time. Use `/sync-envs`
to **refresh** both after the on-server values change (e.g. new
credentials, new feature flag, a `/set-env` edit applied elsewhere).

Idempotent: overwrites the local `.env` files. The server's copy is not
touched.

```bash
set -a && source .env && set +a

services=(backend frontend)
present=()

for svc in "${services[@]}"; do
  if [ -d "work/$svc/.git" ]; then
    bash .claude/scripts/fetch-env.sh "$svc"
    present+=("$svc")
  else
    echo "[skip] work/$svc not cloned — run /work-on $svc or /setup-all"
  fi
done

echo
if [ ${#present[@]} -gt 0 ]; then
  echo "synced: ${present[*]}"
fi
```

If you only need one: `bash .claude/scripts/fetch-env.sh <service>` or
just rerun `/work-on <service>` (which also syncs the env).

The script auto-detects whether it's running on the AniChan server
itself (uses `cp` from `/home/anime/<svc>/.env`) or a remote machine
(uses `scp` with the SSH creds from the control repo's `.env`).
