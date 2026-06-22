---
description: Tail logs for an AniChan container on the server
argument-hint: <container>  e.g. anime-backend | anime-frontend
---

```bash
set -a && source .env && set +a
CONTAINER="${ARGUMENTS:-anime-backend}"

ssh -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" \
  "docker logs --tail 100 -f $CONTAINER"
```

Ctrl-C to stop following. Both containers (`anime-backend`,
`anime-frontend`) run on the external `goongle-network`; tailing is
read-only and safe.

For ingest runs — `scripts/ingest.py` is a standalone CLI, NOT the
running app, so its output does not land in the container logs. When you
kick off an ingest in the background, log it to a file and tail that:

```bash
set -a && source .env && set +a
# start: docker exec anime-backend python -m scripts.ingest <mode> 2>&1 | tee /tmp/ingest-<mode>.log
ssh -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" \
  "tail -n 100 -f /tmp/ingest*.log"
```

(ingest modes: `full`, `years [from] [to]`, `popular [pages]`,
`enrich [limit]`, `sample [n]`.)
