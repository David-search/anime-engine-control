---
description: Open an interactive SSH shell to the AniChan server (vast-canada-2)
---

```bash
set -a && source .env && set +a
ssh -p "$SSH_PORT" "$SSH_USER@$SSH_HOST"
```

Lands you in a shell on `70.30.158.46` (alias `vast-canada-2`,
`ssh -p 43730 root@70.30.158.46`). Useful when probes/log tails aren't
enough and you need to poke around directly.

Once on the box, the two AniChan containers run on the external
`goongle-network`:

```bash
docker ps --filter name=anime-          # anime-backend, anime-frontend
docker logs --tail 100 -f anime-backend
docker logs --tail 100 -f anime-frontend
```

Deploy dirs are `/home/anime/frontend` and `/home/anime/backend` (each
holds the `Dockerfile`, `docker-compose.yml` with `build: .`, and the
`.env` that is the source of truth for runtime config). To rebuild a
service in place:

```bash
cd /home/anime/backend && docker compose up -d --build
cd /home/anime/frontend && docker compose up -d --build
```
