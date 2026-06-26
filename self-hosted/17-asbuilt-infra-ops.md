# 17 · As-built: infrastructure, deploy & ops runbook

The operational reality of AniChan self-hosting, as it actually runs. Where docs
[01](01-ecosystem-and-extractors.md)–[13](13-mapping-rethink.md) cover *why* and
*how* the pipeline is designed, this doc is the **as-built** topology, the full
env/port contract, what process runs where, the deploy loop with its one
load-bearing safety rule, and a short runbook. Present tense, grounded in the
live infra and the real code.

## Two hosts, two trust tiers

AniChan is split exactly along the doc-03/doc-09 line: a **clean tier** that
serves the catalog/API/site, and a **video tier** that acquires and serves the
bytes. They are two physically separate machines.

| | **vast-canada-2** — APP host | **vast-canada-3** — VIDEO ORIGIN |
|---|---|---|
| Address | `70.30.158.46`, ssh alias `vast-canada-2` port `43730` | `159.48.242.1` (vast.ai RTX-4070 GPU node) |
| Role | catalog / search / detail / watch API + the site | acquire → transcode → cache → serve the HLS bytes |
| Lifetime | long-lived (the only "real" host) | **EPHEMERAL** — a rented GPU box (see Key risk) |
| Runs | `anime-frontend`, `anime-backend`, shared `mongodb` + `elasticsearch` (Docker, `goongle-network`) | `nginx` origin, `ingest_api` (tmux), `transmission`, the `/data/*.py` pipeline |
| Source of truth | `/home/anime/{frontend,backend}/.env` | `/data/run_ingest_api.sh` (durable env) + `/data/cache/index.db` |
| Deploy | build-on-server (rsync source → `compose up -d --build`) | edit `/data/*.py` in place; restart the tmux process |

The backend **proxies** the video origin so the browser never learns
`159.48.242.1` — `/m3u8`, `/seg`, `/vtt` all return `/api/watch/...` URLs
([watch.py:131](#)). That hidden-origin property is the whole point of the split:
the ephemeral DMCA-exposed node is never named to a client.

```
                 USERS (browser)  ──────────────────────────────┐
                       │ https://anichan.net                     │ (origin IP
                       ▼                                         │  never sent
   ┌───────────────────────────────────┐                        │  to client)
   │  vast-canada-2  (APP host)         │                        │
   │  ┌──────────────┐  ┌────────────┐  │                        │
   │  │anime-frontend│→ │anime-backend│ │                        │
   │  │  Next.js 15  │  │  FastAPI   │  │                        │
   │  └──────────────┘  └─────┬──────┘  │                        │
   │   mongodb  elasticsearch │         │                        │
   └──────────┬───────────────┼─────────┘                        │
              │ trigger_ingest │ proxy HLS (master/seg/vtt/ass/fonts)
              │ GET /ingest    │ GET {ORIGIN}/{aid}/{ep}/{cat}/...│
              ▼ :35147         ▼ :35346 ◄───────────────────────┘
   ┌───────────────────────────────────┐         POST /api/watch/cache-state
   │  vast-canada-3  (VIDEO ORIGIN)     │ ───────────────────────►  (back to
   │  ingest_api(tmux):8001  nginx:8000 │   {cached,ep_titles,total}  backend
   │  ingest.py → transmission → hls_build → /data/cache  :43577)
   └───────────────────────────────────┘
```

## What runs where

### vast-canada-2 — containers (Docker, `goongle-network`)

`docker ps` (live):

| Container | Host → container | Public | Notes |
|---|---|---|---|
| `anime-frontend` | `8003 → 3000` | `:43879` (`anichan.net`) | Next.js 15 standalone |
| `anime-backend` | `8008 → 8000` | `:43577` | FastAPI |
| `mongodb` | `8002 → 27017` | `:43829` | **shared with goongle**; db `anime_db`, collection `selfhost_cache` |
| `elasticsearch` | `8005 → 9200` | `:43505` | **shared with goongle**; index `anime` |

The frontend and backend deploy from this repo; the two data stores are
host-level and **shared with goongle** — never restart/recreate them (CLAUDE.md
"Ask before destructive ops").

### vast-canada-3 — `/data` layout

Everything lives flat under `/data` (mirrored read-only into
`claude/self-hosted/`):

| Path | Role |
|---|---|
| [`ingest.py`](ingest.py) | orchestrator + CLI: map → discover → select → download → `hls_build` → register → push cache-state |
| [`relparser.py`](relparser.py) | ported Amatsu parser (season-aware, split-cour-proof — see [13](13-mapping-rethink.md)) |
| [`cache_db.py`](cache_db.py) | SQLite index (`/data/cache/index.db`) + LRU eviction + `mapping_cache` |
| [`hls_build.py`](hls_build.py) | H.264 master + NVENC 720/480 ladder + all subs/audio + embedded fonts |
| [`ingest_api.py`](ingest_api.py) | the on-demand trigger HTTP server (`:8001`), two-lane queue |
| [`precache.py`](precache.py) | proactive airing-slate pre-cache worker (feeds the low-priority lane) |
| `run_ingest_api.sh` | durable launcher: bakes the env, `exec python3 ingest_api.py` |
| `cache/` | HLS-at-rest, **~63 GB** live; `{anilist_id}/{ep}/{category}/master.m3u8` |
| `transmission/`, `library/` | torrent client state + extracted source files |

**nginx** serves `/data/cache` as a static file tree: `root /data/cache;
location / { ... }` on `listen 8000` (and `8080`). A request for
`{ORIGIN}/107490/1/sub/master.m3u8` maps directly to
`/data/cache/107490/1/sub/master.m3u8` on disk — no per-viewer transcode, just
file serving (the doc-10 static-HLS-at-rest property).

**`ingest_api`** runs **not as a service but in a tmux session** named
`ingestapi`, launched via the durable `/data/run_ingest_api.sh`:

```bash
#!/bin/bash
exec env \
  INGEST_TOKEN=<shared secret == backend SELFHOST_INGEST_TOKEN> \
  BACKEND_URL=http://70.30.158.46:43577 \
  CACHE_CAP_GB=300 \
  PREFETCH=1 \
  MAX_CONC=2 \
  python3 /data/ingest_api.py
```

The launcher exists so the env contract is **not** lost on a process restart:
`tmux` keeps the process alive across SSH disconnects, and re-running the script
re-applies the exact same `INGEST_TOKEN` / `BACKEND_URL` / cap every time. The
token here and the backend's `SELFHOST_INGEST_TOKEN` are the **same string** —
that shared secret authenticates traffic in *both* directions (backend → node
`/ingest`, node → backend `/cache-state`).

## The port / address / env contract

This is the spine — every value below is load-bearing, and several exist
**nowhere in the repo** (only in the on-server `.env` and `run_ingest_api.sh`).

### Public ports (vast-mapped)

The vast.ai node maps internal ports to random public ports (from the node's
`VAST_TCP_PORT_*` env):

| Internal (vast-canada-3) | Public | Consumed by | Backend env var |
|---|---|---|---|
| nginx `:8000` (HLS origin) | `159.48.242.1:35346` | backend HLS proxy + self-host probe | `SELFHOST_ORIGIN` |
| ingest_api `:8001` | `159.48.242.1:35147` | backend `trigger_ingest` | `SELFHOST_INGEST_URL` |

### Env contract — who sets what, who reads it

| Var | Lives in | Value (live) | Meaning / why |
|---|---|---|---|
| `SELFHOST_CACHE` | backend `.env` | `1` | master flag — enables Source 1, the trigger, and the probe ([config.py:28](#)) |
| `SELFHOST_ORIGIN` | backend `.env` | `http://159.48.242.1:35346` | base the backend probes/proxies: `{ORIGIN}/{aid}/{ep}/{cat}/master.m3u8` ([sources.py:274](#)) |
| `SELFHOST_INGEST_URL` | backend `.env` | `http://159.48.242.1:35147` | where `/servers` fires the fire-and-forget `GET /ingest` ([sources.py:339](#)) |
| `SELFHOST_INGEST_TOKEN` | backend `.env` | *(shared secret)* | sent as `X-Ingest-Token` to the node; **also** the token the node must present on `/cache-state` ([watch.py:157](#)) |
| `INGEST_TOKEN` | node `run_ingest_api.sh` | *(== `SELFHOST_INGEST_TOKEN`)* | node-side: rejects `/ingest` without the matching header ([ingest_api.py:92](#)); also passed to `ingest.py` as the cache-state push secret |
| `BACKEND_URL` | node `run_ingest_api.sh` | `http://70.30.158.46:43577` | where `ingest.py` POSTs cache-state ([ingest.py:28](#),[685](#)). **Public backend port**, because the node is off `goongle-network` and can't resolve `anime-backend` |
| `FRONTEND_HOST_PORT` | frontend `.env` | `8003` | the host→container port the vast external mapping + the `anichan.net` nginx depend on; **not in the repo** |
| `NEXT_PUBLIC_BACKEND_URL` | frontend `.env` | `https://anichan.net` | **baked at build time** (Next.js standalone). Must be the public **https** origin — an `http://IP:port` here is mixed-content-blocked on the https site |
| `BACKEND_URL` (frontend) | frontend `.env` | `http://anime-backend:8000` | SSR-side, **in-network** — different value, same name as the node's `BACKEND_URL`; don't conflate the two |
| `CACHE_CAP_GB` | node | `300` | LRU-evict target after every build ([ingest_api.py:23](#)) |
| `PREFETCH` / `MAX_CONC` | node | `1` / `2` | prefetch N ahead; 2 concurrent builds |

> **One name, two values.** `BACKEND_URL` means two different things: on the
> **video node** it's the **public** backend `http://70.30.158.46:43577` (the
> node is not on `goongle-network`); in the **frontend** container it's the
> **in-network** `http://anime-backend:8000` (SSR). They are not the same value
> and must not be cross-copied.

### The four cross-host calls (and their auth)

| # | Direction | Call | Auth | Code |
|---|---|---|---|---|
| 1 | backend → node | `GET {INGEST_URL}/ingest?anilist_id&ep` (fire-and-forget, 4 s timeout, deduped per `(aid,ep)`) | `X-Ingest-Token` | [sources.py:324](#) |
| 2 | backend → node | `GET {ORIGIN}/{aid}/{ep}/{cat}/master.m3u8` (probe, then proxy segments) | none (static nginx) | [sources.py:272](#) |
| 3 | node → backend | `POST {BACKEND_URL}/api/watch/cache-state` after each build + after eviction | `X-Ingest-Token` | [ingest.py:684](#) |
| 4 | browser → backend | `GET /api/watch/{m3u8,seg,vtt}` (rewritten so origin IP stays hidden) | none | [watch.py:131](#) |

## End-to-end flow (as-built)

```
user opens anime ep N
  │
  ├─►(1) backend /watch/servers  ([watch.py:116])
  │       _bg(trigger_ingest(aid, N))  → fire-and-forget GET node /ingest  (deduped 4s)
  │       resolve_all(): probe self-host concurrently with Miruro ([sources.py:425])
  │
  ▼
node ingest_api  /ingest?anilist_id=N&ep=N         ([ingest_api.py:88])
  │   auth X-Ingest-Token; enqueue(N, N, precache=False)
  │   requested ep → _hi lane; prefetch (N+1) → _lo lane     ([ingest_api.py:64])
  │   already cached → cache_db.touch() (keep warm / anti-evict)
  ▼
worker drains _hi before _lo                        ([ingest_api.py:39])
  │   ingest.py episode N N:
  │     map_anidb(N, want_ep=N)   eid/abs/relnum, cached map if covered & <12h ([ingest.py:149])
  │     find_releases (Tier-0 ?eid= parser-free) → select_release (conf,alive,quality)
  │     transmission download (or batch: add pack, deselect all, fetch 1 file)
  │     hls_build → H.264 master + NVENC 720/480 + all subs/audio + fonts
  │     cache_db.register(...)                       ([ingest.py:669])
  │     push_cache_state(N, mp) → POST backend /cache-state  ([ingest.py:702])
  │   then ingest.py evict <CACHE_CAP_GB>            ([ingest_api.py:53])
  ▼
nginx now serves {ORIGIN}/N/N/sub/master.m3u8 (HTTP 200)
  │
  ▼(2/4) backend proxies HLS → browser plays ★ AniChan (Source 1)
```

Miruro covers the gap **instantly** while a cold episode builds in the
background (the self-host probe runs concurrently, no added latency). On the
next open, the probe hits and ★ AniChan is Source 1.

### Two-lane queue — why it can't starve

`ingest_api` has two bounded `queue.Queue`s: `_hi` (on-demand, cap 50) and `_lo`
(prefetch + pre-cache, cap 60). Workers always `get_nowait()` from `_hi` first
and only fall back to `_lo` ([ingest_api.py:39](#)). The requested episode of an
on-demand open goes to `_hi`; its prefetch and *all* `precache.py` work
(`precache=1`) go to `_lo` ([ingest_api.py:76](#)). The separation is the whole
point: a saturated pre-cache backlog fills `_lo` and can never reject or delay a
real viewer's open — the `_hi` lane has its own capacity. `precache.py` always
sends `precache=1`, so it physically cannot land in `_hi`.

### Cache-state sync — the read-index

After **every** build and after **every** eviction, the node POSTs
`{cached:{sub,dub}, ep_titles, total_eps}` to `/api/watch/cache-state`
([ingest.py:674](#)). The backend upserts the `selfhost_cache` Mongo collection
([watch.py:167](#)); the catalog detail + card endpoints read it for the green
coverage badge + episode titles ([catalog.py:33](#),[51](#)) without ever
probing the origin. The node's `cache_db` stays the source of truth; this is a
denormalized read-index. Eviction calls `push_cache_state` for each affected
anime ([ingest.py:799](#)) so a badge never claims an episode that was evicted.
Both pushes use the cached ani.zip map when possible — no ani.zip hit needed.

## Deploy: build-on-server

There is **no self-hosted runner and no `dev` branch**. The CI/CD workflow
exists but fails (owner must add `SERVER_SSH_KEY`). The working path is
build-on-server, driven by `/deploy-backend` and `/deploy-frontend`:

```
edit work/<svc>/  →  rsync source → /home/anime/<svc>/  →  ssh: compose up -d --build  →  verify health
                     (EXCLUDE .env AND .env.local)
```

| Step | Backend | Frontend |
|---|---|---|
| Sync | `rsync -az --delete --exclude .git --exclude .env --exclude .env.local --exclude __pycache__` | same + `--exclude node_modules --exclude .next --exclude public/jassub` |
| Build | `cd /home/anime/backend && docker compose up -d --build` | `cd /home/anime/frontend && docker compose up -d --build` |
| Verify | `curl $BACKEND_URL/health` → `:43577` | `curl $FRONTEND_URL` 200 → `:43879` |

Compose has `build: .` and reads `/home/anime/<svc>/.env` at run time. For the
frontend, compose additionally passes `NEXT_PUBLIC_BACKEND_URL` as a **build
arg** from that `.env` — it's baked into the standalone bundle, so a wrong value
survives until the next rebuild.

### ⚠️ The NEVER-rsync-local-.env rule (the one that bites)

The on-server `/home/anime/<svc>/{.env,.env.local}` are the **runtime source of
truth** and hold values that exist **nowhere in the repo**:
`FRONTEND_HOST_PORT=8003`, `NEXT_PUBLIC_BACKEND_URL=https://anichan.net`, the
Google client id, the Amplitude key, Mongo/ES creds, and **all `SELFHOST_*`**
(origin, ingest URL, ingest token). The deploy rsyncs **must** carry
`--exclude '.env' --exclude '.env.local'` (they already do). The failure mode if
you clobber them:

| Clobbered value | Symptom |
|---|---|
| `FRONTEND_HOST_PORT` drops | host→container port mapping breaks → **502 at `anichan.net`** |
| `NEXT_PUBLIC_BACKEND_URL` → `http://IP:port` | baked wrong; browser API calls **mixed-content-blocked** on https |
| `SELFHOST_*` lost | self-host source + trigger silently disabled → no ★ AniChan, no auto-ingest |

Two hard sub-rules: **never `scp -r` a whole tree** (scp can't exclude — copy
only the specific changed files); and the server `.env` always wins over the
local `work/<svc>/.env` mirror and these markdown files.

**Recovery if clobbered:** the previous Docker image still has the baked
`NEXT_PUBLIC_*` values —
`docker run --rm --entrypoint sh <old-image-id> -c 'grep -rhoE "https?://[a-z0-9.]+" .next/static | sort -u'`.
For the backend `SELFHOST_*`, re-enter them from this doc's contract table (the
origin/ingest ports come from the node's `VAST_TCP_PORT_8000/8001`) and the
shared token from `/data/run_ingest_api.sh` on the node.

## ⚠️ KEY RISK — vast-canada-3 is ephemeral; its IP/ports can change

`159.48.242.1` is a **rented vast.ai GPU instance**, not owned hardware. On any
re-rent, reboot, or migration:

- **The public IP changes** (`159.48.242.1` → something new).
- **The vast port map changes** — `nginx 8000` and `ingest_api 8001` get **new**
  random `VAST_TCP_PORT_*` values, so `:35346` / `:35147` are not stable.
- The `INGEST_TOKEN` in `run_ingest_api.sh` is re-typed by hand and must stay
  equal to the backend's `SELFHOST_INGEST_TOKEN`.

When the node moves, **three backend values must be updated** (via `/set-env`,
then `/deploy-backend`):

| Old | New source |
|---|---|
| `SELFHOST_ORIGIN=http://159.48.242.1:35346` | new IP + new `VAST_TCP_PORT_8000` |
| `SELFHOST_INGEST_URL=http://159.48.242.1:35147` | new IP + new `VAST_TCP_PORT_8001` |
| `SELFHOST_INGEST_TOKEN` | keep == node `INGEST_TOKEN` (re-sync if regenerated) |

And on the new node: stage `/data/*.py` + `run_ingest_api.sh`, start nginx
(`root /data/cache`), `tmux new -s ingestapi`, run the launcher, then
`ingest.py reindex` (and `precache.py`) to refill `/data/cache` (it does **not**
survive a fresh rent). Until these line up the backend silently falls back to
Miruro — symptom: ★ AniChan vanishes and auto-ingest goes quiet, with no error
(every cross-host call is best-effort / try-except). **First thing to check when
self-host "stops working": is the node up, and do the three values match?**

The pre-cache worker is deliberately **parked on the test node** — it belongs on
a persistent production host, not an ephemeral GPU box whose cache evaporates on
re-rent ([12](12-cold-start-and-instant-playback.md)).

## Runbook

All node commands run over `ssh vast-canada-3`; `cd /data` first.

| Task | Command |
|---|---|
| **Status (node queue)** | `curl -s localhost:8001/status` → `{inflight, queued_ondemand, queued_precache, cap_gb}` |
| **Status (cache)** | `python3 cache_db.py stats` (episodes, GB, pinned, per-ep last_access) |
| **Restart ingest_api** | `tmux kill-session -t ingestapi 2>/dev/null; tmux new -d -s ingestapi '/data/run_ingest_api.sh'` (durable env re-applied) |
| **Attach to log** | `tmux attach -t ingestapi` (detach: `Ctrl-b d`) |
| **Flush the queue** | restart ingest_api — both lanes are in-memory `queue.Queue`s, so a restart drains them; in-flight builds finish on their own |
| **Manual ingest (1 ep)** | `python3 ingest.py episode <aid> <ep>` (dedups, builds, registers, pushes cache-state) |
| **Manual ingest (season)** | `python3 ingest.py series <aid> [--eps 1-12] [--require-complete]` |
| **Coverage report** | `python3 ingest.py coverage <aid>` (obtainable / batch-only / weak / gap) |
| **Evict to cap** | `python3 ingest.py evict 300` (LRU, skips pinned; auto-pushes cache-state for affected anime) |
| **Pin (never evict)** | `python3 cache_db.py pin <aid> <ep>` |
| **Backfill cache-state** | per anime: `python3 -c "import ingest; ingest.push_cache_state(<aid>, ingest.map_anidb(<aid>))"` — uses the cached map, no rebuild, re-syncs Mongo `selfhost_cache` |
| **Rebuild the index** | `python3 cache_db.py reindex` (scans `/data/cache/*/*/*/master.m3u8` — use after a manual cache copy or node migration) |
| **Pre-cache the airing slate** | `python3 precache.py` (one pass) / `--loop` (every `PRECACHE_INTERVAL`) — feeds the `_lo` lane only |
| **Verify origin (off-host)** | `curl -o /dev/null -w '%{http_code}\n' http://159.48.242.1:35346/<aid>/<ep>/sub/master.m3u8` |

On the **app host** (`ssh vast-canada-2`):

| Task | Command |
|---|---|
| Backend health | `curl -fsS http://70.30.158.46:43577/health` |
| Tail backend logs (cache-state / triggers) | `docker logs -f anime-backend` (look for `◆ cache-state` and `▶ watch`) |
| Confirm self-host env is live | `grep SELFHOST /home/anime/backend/.env` |
| Deploy | `/deploy-backend` · `/deploy-frontend` (build-on-server, env-safe) |
| Change a runtime value | `/set-env` (edits the canonical on-server `.env`, re-syncs mirror) then `/deploy-<svc>` |

---

**Cross-refs:** [09 streaming-at-scale](09-streaming-at-scale.md) (ingest-vs-serve
split, why Seanime is never the origin) · [11 ingest-automation](11-ingest-automation.md)
(the pipeline internals) · [12 cold-start](12-cold-start-and-instant-playback.md)
(pre-cache rationale) · [13 mapping-rethink](13-mapping-rethink.md) (eid-driven
split-cour mapping). Backend code: `app/config.py`, `app/sources.py`,
`app/routers/watch.py`, `app/routers/catalog.py`. Node code: `/data/*.py`.
