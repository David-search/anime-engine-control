---
description: Run the AniList → Mongo/ES catalog pipeline on vast-canada-2
argument-hint: <mode> — full | years [from] [to] | popular [pages] | enrich [limit] | sample [n]
---

`/ingest $ARGUMENTS`

Runs the standalone catalog pipeline inside the backend container. The
ingest script (`scripts/ingest.py`) is a CLI — it is **not** imported by
the running app. It is the **only** AniList GraphQL caller; the request
path is otherwise pure Mongo/ES reads. AniList is paced at **~2.2s per
request** (AniList caps offset pagination at ~5000 entries and degrades
to ~30 req/min), so a `full` run takes a while — let it run.

```bash
set -a && source .env && set +a
MODE="${ARGUMENTS:-sample 5}"

LOG="/tmp/ingest-$(echo "$MODE" | tr ' ' '-').log"
ssh -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" \
  "docker exec anime-backend python -m scripts.ingest $MODE 2>&1 | tee $LOG"
```

For a long sweep (`full`, `years`, big `enrich`), run detached and watch
the log instead:

```bash
ssh -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" \
  "nohup docker exec anime-backend python -m scripts.ingest $MODE \
     > /tmp/ingest.log 2>&1 &"

# watch progress
ssh -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" 'tail -f /tmp/ingest.log'
```

## Modes

| Mode | What it does |
|---|---|
| `full` | Full catalog build: a popularity sweep **plus** per-`startDate`-year slices (works around AniList's ~5000-entry offset cap by partitioning the catalog by year). Longest run. |
| `years [from] [to]` | Ingest only the given start-year range (e.g. `years 2015 2020`). Useful to backfill or refresh a window without a full sweep. |
| `popular [pages]` | Popularity-ordered sweep, `pages` deep. Fast way to seed the most-popular head of the catalog. |
| `enrich [limit]` | Per-anime heavy fields — relations, characters, staff, recommendations, reviews. **Idempotent catch-up**: only touches docs that are missing the `characters` field, so re-running just continues where it left off. `limit` caps how many docs it enriches this run. |
| `sample [n]` | Ingest a small `n`-doc sample. Smoke test for the pipeline + Mongo/ES wiring. |

After ingest, indexed docs land in MongoDB `anime_db.anime` and the ES
`anime` index. Confirm with [`/test-search`](test-search.md).

> Pacing note: at ~2.2s/request, plan around the AniList rate budget.
> `enrich` is safe to interrupt and resume — it never re-processes a doc
> that already has `characters`.
