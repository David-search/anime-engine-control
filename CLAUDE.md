# anime-engine-control — orchestration plane

This repo is **docs + Claude config**, not source. Cloned anywhere with
a populated `.env`, it gives a fresh Claude session everything needed to
inspect, edit, test, and deploy the AniChan stack — over SSH and HTTP.
AniChan is a HiAnime-style anime catalog + streaming site, **live in
production at https://anichan.net**. It spans **three hosts**:

- **web-goongle** (`66.55.65.89`, ssh alias `web-goongle`) — the public
  **nginx TLS edge**. Terminates HTTPS for `anichan.net` (Let's Encrypt)
  and reverse-proxies to vast-canada-2: `/` → the Next.js app (`:43879`),
  `/api/` + `/api/watch/` → the FastAPI backend (`:43577`; `/api/watch/`
  is a stream-through location for HLS). **Shared** with goongle (it also
  serves `goongle.net`) — only ever touch the `anichan.net` vhost
  (`/etc/nginx/sites-enabled/anichan.net`). Password-auth SSH for now.
- **vast-canada-2** (`70.30.158.46`, ssh alias `vast-canada-2`,
  port `43730`) — the **app host**. Runs both AniChan containers
  (`anime-frontend`, `anime-backend`) plus the shared data stores
  (`mongodb`, `elasticsearch`), all on the external Docker network
  `goongle-network`. The data stores are shared with goongle; AniChan
  uses its **own** Mongo database (`anime_db`) and ES index (`anime`),
  never goongle's. (canada-2 is also build-farm node + ingest callback target.)
- **offshore** (`185.255.120.59`, ssh alias `offshore`) — the **HLS
  storage/origin** for self-hosted video: nginx static-serves `/srv/hls`
  (~17 TB, DMCA-ignored). It *should* serve the anime bytes directly, but
  today the backend still proxies segments through canada-2 (the
  bandwidth-offload gap — see [Self-host](#self-host-video-pipeline-separate-from-the-app)).
  Filled by a separate **6-node build farm** (`canada-2..7`).

**No Qdrant, no embedder, no image/face search** — the backend request
path is pure Mongo/ES reads, plus the Miruro stream resolver and the
self-host origin for `/api/watch/*`. Anything that mentions Qdrant,
embedder, faces, image-search, a `dev` branch, or a self-hosted runner is
goongle's, not ours, and is stale here.

Read [README.md](README.md) for setup. This file is the architectural
overview Claude reads on every session.

## Session start (instruction to Claude)

The SessionStart hook (`.claude/scripts/session-start.sh`, wired in
`.claude/settings.json`) does two things at every session start:

1. **Sync `anime-engine-control` itself** with `origin/main`
   (fast-forward only). Skips if you have uncommitted changes or
   unpushed commits — those are flagged in the banner instead of
   silently merged.
2. **Inventory + auto-sync `work/`** — for each of the two service
   repos: if cloned, fast-forward `main` (skipped on uncommitted edits,
   ahead, or diverged); if not cloned, clone it and sync its `.env`
   from the server. Banner uses `✓` for already-present and `+` for
   freshly-cloned.

On the first turn of every session, before responding to the user's
prompt:

1. Greet the user briefly.
2. **Read [STATE.md](STATE.md)** — the current snapshot of what's deployed,
   what's running, and the PENDING list. This is how a fresh session knows
   "what's up." Surface the headline + any open PENDING items.
3. **Run `/startup`** (or offer to) — the live check: git behind/ahead on the
   control + service repos, app health, the 6 build-farm nodes, offshore, and
   fill progress. Flag anything off (a node UNREACHABLE, a repo behind origin,
   offshore low on space).
4. Render the **System diagram** below verbatim (the box-drawing block).
5. Summarise the `work/` state from the SessionStart banner — present
   clones with branch + sha, missing ones with the suggested
   `/setup-all` or `/work-on <service>`.
6. Note anything unusual (behind origin/main, missing repos, an unreachable
   build node) so the user can decide what to do.
7. Then proceed with whatever they asked for.

Keep the greeting short — the diagram + state summary is the
substantive part. Don't include the diagram on subsequent turns.

## System diagram

```
                              USERS (browser)
                                    │  https://anichan.net
                                    ▼
                       ┌──────────────────────────┐
                       │  nginx TLS edge          │   host web-goongle (66.55.65.89)
                       │  anichan.net · LetsEncrypt│   SHARED with goongle.net
                       │  /→app  /api,/api/watch→be│   touch anichan.net vhost only
                       └────────────┬─────────────┘
                                    │  proxy_pass → vast-canada-2 raw ports
                                    ▼
                       ┌──────────────────────────┐
                       │   frontend (Next.js 15)  │   anime-engine-frontend
                       │   container anime-frontend│   NEXT_PUBLIC_BACKEND_URL
                       │   host :8003 → :3000     │   = https://anichan.net (baked)
                       └────────────┬─────────────┘
                                    │
                       catalog / search / detail / watch  (all under /api)
                       /api/catalog/*  /api/search  /api/watch/*
                                    │
                                    ▼
                       ┌──────────────────────────┐
                       │     backend (FastAPI)    │   anime-engine-backend
                       │     container anime-backend│   single main branch
                       │     host :8008 → :8000   │   public :43577
                       └────┬─────────────────┬───┘
                            │                 │
                  catalog / │                 │ search-as-you-type
                  detail    │                 │ suggest + facets
                  reads     ▼                 ▼
            ┌────────────────────┐   ┌──────────────────────┐
            │     MongoDB        │   │   Elasticsearch 8.13 │
            │  container mongodb │   │  container elasticsearch│
            │  in-net :27017     │   │  in-net :9200        │
            │  host :8002        │   │  host :8005          │
            │  ext  :43829       │   │  ext  :43505         │
            │  db anime_db       │   │  index "anime"       │
            │  ┌────────────────┐│   │  ┌──────────────────┐│
            │  │ anime   users  ││   │  │ search_as_you_   ││
            │  │ comments  likes││   │  │  type suggest    ││
            │  │ history  lists ││   │  │ genre/tag/source/││
            │  │ watchlist      ││   │  │  season facets   ││
            │  │ selfhost_cache ││   │  │ title en+romaji  ││
            │  └────────────────┘│   │  │  +native         ││
            └─────────▲──────────┘   │  └──────────────────┘│
                      │              └──────────▲───────────┘
                      │  upsert catalog         │  index docs
                      │  + heavy fields         │  (genres/tags/
                      │                         │   facets/titles)
                      └───────────┬─────────────┘
                                  │
                       ┌──────────┴───────────┐
                       │  scripts/ingest.py   │   standalone CLI,
                       │  (backend repo)      │   NOT imported by app
                       │  paced ~2.2s/req     │
                       └──────────▲───────────┘
                                  │ GraphQL
                       ┌──────────┴───────────┐
                       │  AniList GraphQL     │   graphql.anilist.co
                       │  catalog source      │   (offset cap 5000;
                       │                      │    ~30 req/min degraded)
                       └──────────────────────┘
```

**Mongo `anime_db` — 9 collections:** `anime` (catalog) · `users` (auth:
email+password / Google) · `comments` (per-anime) · `likes` (per-anime) ·
`history` (resume-watching position) · `watchlist` ("My List", flat bookmarks) ·
`lists` (one model, two kinds: public ranked **tops** + private **collections**) ·
`list_ratings` (1–5 ratings on public lists) · `selfhost_cache` (self-host coverage
marks: `_id`=anilistId → `cached.{sub,dub}` ep lists, `ep_titles`, `total_eps`).

**Per-request flows** (the public path is `https://anichan.net` → edge → canada-2)

Catalog / detail:
```
frontend → backend
backend → Mongo anime_db.anime   (/api/catalog/* — list / single anime read)
backend ← docs → frontend
```

Search (search-as-you-type):
```
frontend → backend
backend → ES "anime"             (suggest + faceted query)
backend ← hits → frontend
```

Trending (the one cached AniList passthrough):
```
frontend → backend /api/catalog/trending
backend → AniList TRENDING_DESC  (in-process cache, 30 min TTL)
backend ← list → frontend
```

Watch (self-hosted #1 + Miruro fallbacks):
```
frontend → backend /api/watch/servers?anilistId&ep&category
backend → SELFHOST_ORIGIN probe   ⎫ run CONCURRENTLY; cached ep → Source 1
backend → Miruro secure-pipe      ⎭ "AniChan · self-hosted", else curated hosts
backend → /api/watch/{m3u8,seg,vtt} proxy  (hides origin IP, SSRF-guarded, Range)
backend ← ranked sources (dual-audio + subs) → frontend (hls.js / JASSUB)
(on-open auto-cache trigger DISABLED 2026-06-26 — caching is a manual/farm step)
```

Ingest (offline, manual; not on the request path):
```
docker exec anime-backend python -m scripts.ingest <mode>
ingest → AniList GraphQL          (paced ~2.2s/req)
ingest → Mongo anime_db.anime     (upsert catalog + heavy fields)
ingest → ES "anime"               (index searchable docs)
```

## Repo → branch → container map

A single `main` branch per service repo. There is **no `dev` branch**
and **no self-hosted runner**.

| Repo                    | `main` deploys to                       | Deploy mechanism                          |
|-------------------------|-----------------------------------------|-------------------------------------------|
| `anime-engine-frontend` | `anime-frontend` (host `:8003` → `:3000`, public `:43879`) | build-on-server: sync source → `compose up -d --build` |
| `anime-engine-backend`  | `anime-backend` (host `:8008` → `:8000`, public `:43577`)  | build-on-server: sync source → `compose up -d --build` |

The shared data stores (`mongodb`, `elasticsearch`) are not deployed by
this repo — they're long-lived containers owned at the host level.

## Infrastructure addresses

Three hosts: the **web-goongle** nginx edge (public TLS), the
**vast-canada-2** app host (containers + data stores), and the
**offshore** HLS origin. The app port table is below; the edge + offshore
are summarised under it and detailed in
[.claude/guides/infrastructure.md](.claude/guides/infrastructure.md). From this
repo (any machine), use `<external>`. From on the server, use
`localhost:<host>` or the in-network container name.

### vast-canada-2 (`70.30.158.46`) — the app host

| Service             | Container        | In-network            | Host             | External                | Auth                                            |
|---------------------|------------------|-----------------------|------------------|-------------------------|-------------------------------------------------|
| Frontend            | `anime-frontend` | `anime-frontend:3000` | `localhost:8003` | `70.30.158.46:43879`    | none                                            |
| Backend             | `anime-backend`  | `anime-backend:8000`  | `localhost:8008` | `70.30.158.46:43577`    | none                                            |
| MongoDB             | `mongodb`        | `mongodb:27017`       | `localhost:8002` | `70.30.158.46:43829`    | `admin:<stored in control .env on the server>`, db `anime_db` |
| Elasticsearch 8.13  | `elasticsearch`  | `elasticsearch:9200`  | `localhost:8005` | `70.30.158.46:43505`    | `elastic:<stored in control .env on the server>`, index `anime` |
| SSH                 | host             | —                     | —                | `ssh -p 43730 root@70.30.158.46` (alias `vast-canada-2`) |                            |

All containers run on the external Docker network `goongle-network`, so
they resolve each other by container name. The on-server deploy dirs
are `/home/anime/frontend` and `/home/anime/backend` — each holds a
`Dockerfile`, a `docker-compose.yml` (with `build: .`), and a `.env`
that is the **source of truth** for that service's runtime config.
(`/home/anime/` also has `mongo/` + `elastic/` compose dirs for the
shared data stores.)

### web-goongle (`66.55.65.89`) — public nginx TLS edge

The public face of `anichan.net`. nginx terminates HTTPS (Let's Encrypt
`CN=anichan.net`) and reverse-proxies to canada-2's external ports:

| Public path | proxied to (canada-2) | nginx mode |
|-------------|------------------------|-----------|
| `/` | `70.30.158.46:43879` (Next.js `anichan_app`) | buffered |
| `/api/watch/` | `70.30.158.46:43577` (FastAPI `anichan_api`) | **stream-through** (no buffering, Range, 120s) — HLS |
| `/api/` | `70.30.158.46:43577` (FastAPI `anichan_api`) | buffered, 30s |

`80 → 301 https`; `www → apex`. vhost: `/etc/nginx/sites-enabled/anichan.net`.
**Shared host** — also serves `goongle.net`; never touch other vhosts or
reload nginx without scoping the blast radius. SSH: `web-goongle` alias
(password auth, `EDGE_PASSWORD`).

### offshore (`185.255.120.59`) — HLS storage/origin

nginx static-serves `/srv/hls/{anilistId}/{ep}/sub/{master.m3u8,v0,a0,a1,subs}`
(~17 TB; CORS `*`, Range/206). Filled by the build farm; see
[Self-host](#self-host-video-pipeline-separate-from-the-app) + [RUNBOOK](self-hosted/RUNBOOK.md).

**Public URLs**

| | |
|---|---|
| Site | **`https://anichan.net`** (live; via the web-goongle edge) |
| Frontend (origin) | `http://70.30.158.46:43879` (behind the edge) |
| Backend (origin)  | `http://70.30.158.46:43577` (behind the edge) |

The frontend bakes **`NEXT_PUBLIC_BACKEND_URL=https://anichan.net`** at
image-build time, so the browser reaches the backend through the edge over
HTTPS (same origin — no mixed-content); SSR inside the container reaches it
in-network as `http://anime-backend:8000`.

## Self-host video pipeline (separate from the app)

The app above (canada-2) is pure catalog/search/proxy. Owning the video bytes
("★ AniChan · self-hosted") is a **separate build farm** that acquires, encodes,
and ships HLS to an offshore origin the backend auto-serves. **Full ops detail is
in [self-hosted/RUNBOOK.md](self-hosted/RUNBOOK.md)** (topology, provisioning,
monitoring, fixes); design rationale in [self-hosted/](self-hosted/) `01..18-*.md`
and memory ([[self-hosted-direction]], [[eweka-multiaccount-scaling-and-usenet-providers]],
[[dead-torrent-live-fallback]], [[animetosho-db-dump-goldmine]]). Roles:

| Role | Host(s) | What it does |
|------|---------|--------------|
| **App** | `vast-canada-2` (above) | backend live-probes + proxies the origin via `SELFHOST_ORIGIN`; `selfhost_cache` Mongo coll = catalog "cached" badges |
| **Build farm** | **6 nodes** `canada-2..7` (vast.ai GPUs) | per node: resolve (AnimeTosho dump / live Nyaa) → download (NZBGet+Eweka primary, transmission fallback) → encode (NVENC Y-mode) → ship-and-delete |
| **HLS origin** | `offshore` (`185.255.120.59`, 17 TB, 16 TB cap) | nginx static-serves `/srv/hls/{anilistId}/{ep}/sub/master.m3u8` (CORS *, Range/206); DMCA-ignored video host |

**Build farm = 6 nodes across 3 Eweka Usenet accounts** (acct hard limit ≈ 20
conns + 2 source IPs → 2 nodes/account, 8 conns/node): acct1→canada-3+4,
acct2→canada-5+6, acct3→canada-2+7. `canada-1` = goongle-prod, **not** used. All
node host:ports, Eweka creds, offshore + ingest token live in [.env](.env) (keys
`NODE_CANADA2..7`, `EWEKA1..3_*`, `OFFSHORE_*`, `SELFHOST_INGEST_TOKEN`).

Each node ships over ssh (key auth) and **never stores** — download→encode→ship→`rm`
(disk stays bounded; accumulation is a bug). Autonomy: 3 tmux supervisors
(`farm`/`nzbget`/`trd`) + a `*/2` cron watchdog (`ensure_up.sh`) keep it running
unattended. Dead dump-torrents (frozen 2026-05-08 seeders) are recovered inline via
**live Nyaa packs** (`nzb_farm.live_fallback` → `dump_resolver.resolve_anime_live`,
AV1-skipped + size-capped to stay remuxable). Backend env (canada-2
`/home/anime/backend/.env`): `SELFHOST_CACHE=1`, `SELFHOST_ORIGIN=http://185.255.120.59`.

**Serving = Bunny CDN, token-signed** (deployed 2026-06-29). The self-host source serves
the heavy bytes (segments/subtitles/fonts) **direct from `cdn.anichan.net`** (Bunny
pull-zone → offshore), token-signed for anti-scrape; only the KB-sized playlists proxy
through canada-2 (`/api/watch/m3u8`, which strips subtitle groups + rewrites children to
signed CDN URLs). Env: `SELFHOST_CDN_BASE=https://cdn.anichan.net`, `SELFHOST_CDN_TOKEN_KEY`
(secret), `SELFHOST_CDN_TTL=43200`. The origin IP stays hidden; retiring the CDN = blank
`SELFHOST_CDN_BASE` (proxy fallback) or a DNS flip. **Full design + the anti-scrape model +
the Cloudflare/backup plans: [self-hosted/19-cdn-token-auth-and-hardening.md](self-hosted/19-cdn-token-auth-and-hardening.md).**
Build-farm scripts live in [self-hosted/](self-hosted/)
(`dump_resolver.py`, `nzb_farm.py`, `nzb_acquire.py`, `ingest.py`, `hls_build.py`,
`run_node.sh`, `nzbget_supervisor.sh`, `ensure_up.sh`, `partition.py`), mirrored to
each node's `/data/` and to the backend repo's `selfhost/`. ssh aliases:
`vast-canada-2..7`, `offshore` (all key auth, in `~/.ssh/config`).

## Deploy semantics per service

There is **no self-hosted runner and no `dev` branch** (this is the
biggest difference from goongle). The primary path is **build-on-server**.

| Path                         | What happens                                                                                                                                |
|------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------|
| **Build on server** (primary)| Sync the service source to `/home/anime/<svc>/` over `vast-canada-2` (rsync or scp), then `ssh vast-canada-2 'cd /home/anime/<svc> && docker compose up -d --build'`. Compose has `build: .` and reads `/home/anime/<svc>/.env`. Then verify the public health URL. |
| **CI/CD alt** (not working yet)| Each repo has `.github/workflows/ci-cd.yml`: push `main` → GitHub Actions builds the image → `docker save \| gzip` → scp → ssh `docker load` + `compose up`. It currently **fails** until the repo owner adds the GitHub Actions secrets below. Claude **cannot** set GitHub secrets — only the owner can, in repo Settings. |

CI/CD secrets the owner must add (Claude cannot):

| Repo                    | Secret                  | Value                                |
|-------------------------|-------------------------|--------------------------------------|
| both                    | `SERVER_SSH_KEY`        | private key for `root@70.30.158.46:43730` |
| `anime-engine-frontend` | `NEXT_PUBLIC_BACKEND_URL` | `http://70.30.158.46:43577`        |

`/deploy-backend` and `/deploy-frontend` drive the build-on-server flow
(sync source → `compose up -d --build` → verify health), not the CI/CD
path.

## Standing conventions

- **Work locally, then deploy.** Any change beyond a one-line config
  tweak: `/work-on <service>` first (clones into `work/<service>/` if
  not already there, fast-forwards `main`), edit + grep + run tests at
  filesystem speed, then `/deploy-<service>` to sync the source to the
  server and rebuild. Don't drive multi-file edits over SSH `vim`.
- **Pre-clone both if you'll touch more than one.** `/setup-all` runs
  the two `/work-on`s in parallel. Useful for cross-service exploration
  (`grep -r 'catalog' work/`).
- **`work/<service>/.env` is auto-synced from the server.** `/work-on`
  and `/setup-all` `scp` (or `cp` if running on-server) the canonical
  `.env` from `/home/anime/<svc>/.env` into the local clone. `/sync-envs`
  re-pulls both after on-server values change. **The server is the
  source of truth; never edit `work/<service>/.env` directly** — edits
  get clobbered on the next sync.
- **To change a runtime config, use `/set-env`.** Updates the canonical
  `/home/anime/<svc>/.env` over SSH (or directly when on-server) and
  re-syncs the local mirror. The next `/deploy-<service>` rebuilds the
  container and picks up the new value. **ALWAYS ask the user before
  manually restarting a container** — most edits get picked up on the
  next deploy and don't need an out-of-band restart.
- **Running a service locally: native, not docker.** When the user asks
  to run a service from `work/<service>/`, do **not** suggest
  `docker compose up`. The synced `.env` files use **in-network**
  hostnames (`mongodb://...@mongodb:27017`, `http://elasticsearch:9200`,
  `http://anime-backend:8000`) that only resolve inside `goongle-network`
  on the server. From a developer laptop those names don't resolve, and
  `docker compose up` would just produce connection-refused errors.

  Run natively against the **external** infrastructure addresses instead:

  | Service  | Native runtime                                                                                  |
  |----------|-------------------------------------------------------------------------------------------------|
  | backend  | `pip install -r requirements.txt && python -m uvicorn app.main:app --reload --port 8000`        |
  | frontend | `npm install && npm run dev` (Next.js on `:3000`)                                                |

  Before running, override the in-network URLs in `work/<service>/.env`
  to their external equivalents (or `export` them before launch):

  ```dotenv
  MONGO_URI=mongodb://admin:<password>@70.30.158.46:43829/anime_db?authSource=admin
  ELASTIC_URL=http://70.30.158.46:43505
  ```

  This is **only** for local debugging from a laptop. The on-server
  containers continue to use the in-network URLs (correctly), and the
  sync from server will overwrite these laptop-side overrides next time
  `/sync-envs` runs — that's expected.
- **Env source of truth = `/home/anime/<svc>/.env` on the server.**
  Not the local `work/<svc>/.env` mirror, not these markdown files.
  When they disagree, the server `.env` wins.
- **⚠️ NEVER sync a local env file over the server — exclude `.env`
  AND `.env.local` on every deploy sync.** The on-server
  `/home/anime/<svc>/{.env,.env.local}` hold values that exist **nowhere
  in the repo**: `FRONTEND_HOST_PORT=8003` (the host→container port the
  vast external mapping + nginx depend on), `NEXT_PUBLIC_BACKEND_URL=https://anichan.net`
  (baked into the frontend at build time — must be the public https
  origin, an `http://IP:port` here is mixed-content-blocked), the Google
  client id, the Amplitude key, Mongo/ES creds, and `SELFHOST_*`.
  Overwriting them with a dev-local copy silently breaks production: the
  port mapping drops (→ 502 at the domain) and the next build bakes a
  broken backend URL. The `/deploy-<service>` commands already carry
  `--exclude '.env' --exclude '.env.local'`; **if you ever rsync/scp by
  hand, carry the same excludes** (and never `scp -r` a whole tree — scp
  can't exclude; copy only the specific changed files). Recovery, if
  clobbered: the previous Docker image still has the baked
  `NEXT_PUBLIC_*` values — `docker run --rm --entrypoint sh <old-image-id>
  -c 'grep -rhoE "https?://[a-z0-9.]+" .next/static | sort -u'`.
- **Don't ask permission for routine work.** Probes (`/probe-es`,
  `/probe-mongo`), log tails (`/tail-logs`), and test runs
  (`/test-search`) execute without prompts. Pause only for genuinely
  destructive ops (dropping the ES `anime` index, deleting the Mongo
  `anime_db`, force-pushes, **container restarts/rebuilds**).
- **Ask before destructive ops and container restarts.** The data
  stores are **shared with goongle** — never restart, recreate, or
  reconfigure `mongodb` / `elasticsearch`, and never drop a collection
  or index without explicit confirmation. Scope the blast radius before
  any rebuild.
- **Test after every search-code change.** `/test-search` is the
  contract — must stay green.
- **Edits flow through git.** Never `ssh server vim file.py`. Use
  `/work-on <service>` to clone, edit locally, commit, push, then
  `/deploy-<service>` to build on the server.
- **Don't commit secrets.** Never write the real Mongo/ES passwords
  into any committed file — use the literal placeholder
  `<stored in control .env on the server>`. The push auto-classifier
  blocks commits containing the real password. Real values live only in
  the gitignored `.env` here and in `/home/anime/<svc>/.env` on the server.
- **Infra reality outranks the docs — reconcile them, don't just
  report.** Any time you inspect or touch infrastructure (`ssh`,
  `docker ps`, probing ES/Mongo, reading an on-server `.env`, checking
  ports/hosts/index names/collection names) and find that reality
  differs from what this repo claims, **fix the docs in the same
  session** — not "later," not just a note in chat. The sources of
  truth are the **live infra** and the **on-server
  `/home/anime/<svc>/.env`**, never the local `work/<svc>/.env` mirror
  or these markdown files. Update every place that repeats the stale
  fact: `CLAUDE.md` (intro host, System diagram, address tables,
  conventions), [.claude/guides/infrastructure.md](.claude/guides/infrastructure.md), and
  any `repos/*/CLAUDE.md`. Then re-`grep` the docs for the obsolete term
  to catch every copy.
- **Markdown links for code references** (`[file.py:42](path#L42)`),
  not backticks.
- **⭐ EVERY change is captured in the md files — no design lives only in chat.**
  This is the cardinal rule of this repo. Code changes, infra changes, **and
  architecture decisions / design ideas / "why we chose X" / plans we're
  deferring** all get written down **in the same session**, before the chat
  ends — because when the session ends, anything only in chat is **lost**.
  Where it goes:
  - **[STATE.md](STATE.md)** — the current snapshot + the **PENDING** list
    (what's deployed, what's running, what's decided-but-not-done). Update it
    every session. A new session reads it first.
  - **`self-hosted/NN-*.md`** — as-built designs + rationale (the numbered
    series; add the next number for a new subsystem, e.g. the CDN doc `19`).
  - **`CLAUDE.md` / `infrastructure.md` / `repos/*/CLAUDE.md`** — the live
    overview, addresses, and service detail.
  - A decision you make in conversation (e.g. "we'll use Bunny, gray-cloud the
    CDN", "offshore needs a backup mirror", "skip in-app rate-limit, use
    Cloudflare") is an **architecture decision** → record the decision **and the
    reasoning** so it survives. If you can't tell where it goes, put it in
    STATE.md PENDING with a one-line why.
- **Update anime-engine-control docs in the same commit as the change.**
  Stale docs are worse than no docs. When you change something in this
  repo, update the relevant files in the SAME commit — don't leave it
  for "later." The mapping below is the rule of thumb; if a change
  touches multiple categories, update each. If unsure, grep the docs for
  terms the change makes obsolete and verify they all still match reality.

  | Change                                          | Docs to update                                                                 |
  |-------------------------------------------------|--------------------------------------------------------------------------------|
  | Add / remove / rename a slash command           | `README.md` (slash command examples), `CLAUDE.md` Key docs section if listed   |
  | Change a slash command's behavior               | `.claude/commands/<name>.md` itself (the body IS the doc), plus any guide that references it |
  | Change a service deploy flow                    | `.claude/guides/deploy-loop.md`, `repos/<service>/CLAUDE.md`, `.github/workflows/ci-cd.yml` in the service repo if CI-side |
  | Change the env contract (new key, renamed key)  | `.env.example`, `.claude/guides/secrets.md`, the relevant `repos/<service>/CLAUDE.md` if it documents the key |
  | Change infrastructure (new port, new container) | [.claude/guides/infrastructure.md](.claude/guides/infrastructure.md), the port/address tables in `CLAUDE.md` |
  | Discover infra reality ≠ docs (host, port, index, collection, on-server env) | `CLAUDE.md` (intro host + System diagram + address tables), [.claude/guides/infrastructure.md](.claude/guides/infrastructure.md), affected `repos/*/CLAUDE.md` — then re-grep for the stale term |
  | Change the ingest pipeline (new mode, new field)| `.claude/commands/ingest.md`, the System diagram above, `repos/backend/CLAUDE.md` |
  | Change the self-host build farm (node add/rotate, Eweka acct, pipeline script, fix) | [self-hosted/RUNBOOK.md](self-hosted/RUNBOOK.md), the Self-host section + table above, [.claude/guides/infrastructure.md](.claude/guides/infrastructure.md) build-farm tables, `.env`/`.env.example` (`NODE_CANADA*`, `EWEKA*`), the `/farm-*` command if behavior changed |
  | Change CDN serving / token auth / anti-scrape (Bunny, `SELFHOST_CDN_*`, CORS, Cloudflare, rate-limit) | [self-hosted/19-cdn-token-auth-and-hardening.md](self-hosted/19-cdn-token-auth-and-hardening.md), the Self-host serving paragraph above, [STATE.md](STATE.md) (deployed/PENDING), `.env`/`.env.example`, `repos/backend/CLAUDE.md` (the `_emit`/`_sign` logic) |
  | Make an architecture **decision** (chose X over Y, deferred a plan)     | [STATE.md](STATE.md) PENDING (the decision + the why), and a `self-hosted/NN-*.md` if it's a design — per the ⭐ cardinal rule above |
  | Change a Convention or rule                     | This section, plus `.claude/guides/safety.md` if it's a safety boundary        |
  | Add / remove a hook or settings rule            | `.claude/settings.json` (the change), `CLAUDE.md` Session start section if user-visible |

  After committing, do a quick `grep` against the docs for any term the
  change just made obsolete — typo'd container names, removed env vars,
  retired ports. Stale docs accumulate fast otherwise.

## Catalog source & data pipeline

The catalog comes from **AniList GraphQL** (`https://graphql.anilist.co`).
The catalog id **is** the AniList id (`idMal` is carried for host
mapping). The **only** AniList caller is the ingest script — the backend
request path is pure Mongo/ES reads, with **one** cached exception:
`/api/catalog/trending` mirrors AniList `TRENDING_DESC`, cached in-process
for 30 min. (MAL/Jikan + TMDB are possible **future** enrichment, not
wired.)

The backend repo ships `scripts/ingest.py` — a standalone CLI, **not**
imported by the running app. It's paced at ~2.2s/req because AniList
caps offset pagination at 5000 entries and degrades to ~30 req/min.
Modes:

| Mode                     | What it does                                                                                                  |
|--------------------------|--------------------------------------------------------------------------------------------------------------|
| `full`                   | popularity sweep + per-`startDate`-year slices                                                                |
| `years [from] [to]`      | ingest a year range                                                                                           |
| `popular [pages]`        | ingest top-popularity pages                                                                                   |
| `enrich [limit]`         | per-anime heavy fields (relations / characters / staff / recommendations / reviews); idempotent catch-up — only touches docs missing the `characters` field |
| `sample [n]`             | small smoke sample                                                                                            |

Run on the server: `docker exec anime-backend python -m scripts.ingest <mode>`.
`/ingest <mode>` wraps this over SSH.

## Key docs (centralised here)

- **[STATE.md](STATE.md) — read first on a new session.** Current snapshot
  (what's deployed/running) + the **PENDING** list. `/startup` checks it live.
- [.claude/guides/infrastructure.md](.claude/guides/infrastructure.md) — host, port table,
  addresses, credentials, data stores, **+ the 6-node build farm / Eweka / offshore topology**.
- [self-hosted/RUNBOOK.md](self-hosted/RUNBOOK.md) — **self-host build-farm ops**
  (6-node topology, provisioning, monitoring, dead-torrent + disk fixes). Driven by
  `/farm-status`, `/farm-fix`, `/farm-provision`.
- [self-hosted/19-cdn-token-auth-and-hardening.md](self-hosted/19-cdn-token-auth-and-hardening.md)
  — **CDN serving (Bunny `cdn.anichan.net`) + token auth + the anti-scrape model** + the
  Cloudflare / offshore-backup / rate-limit plans.
- [BUILD-PLAN.md](BUILD-PLAN.md) — architecture & phased build.
- [research/](research/) — how anime streaming sites work, host
  integration, costs, pitfalls. **As-built:**
  [streaming-pipeline-and-player.md](research/streaming-pipeline-and-player.md)
  (Miruro resolver, proxy, sources, player) and
  [user-features-and-page-architecture.md](research/user-features-and-page-architecture.md)
  (auth, comments, watchlist/Tops/Collections, the player-on-anime-page merge,
  bug fixes).
- [.claude/guides/architecture.md](.claude/guides/architecture.md) —
  high-level cross-service architecture (this is what `/architecture`
  summons).
- [.claude/guides/deploy-loop.md](.claude/guides/deploy-loop.md) —
  edit → sync → build-on-server → verify flow per service.
- [.claude/commands/ingest.md](.claude/commands/ingest.md) — AniList → Mongo
  → ES pipeline, the ingest CLI modes.
- [.claude/guides/safety.md](.claude/guides/safety.md) — shared-data-store
  boundaries (Mongo/ES are shared with goongle).
- [.claude/guides/secrets.md](.claude/guides/secrets.md) — `.env`
  management, the secrets placeholder rule.
- [repos/backend/CLAUDE.md](repos/backend/CLAUDE.md) — service-level
  detail Claude reads when working on the backend.
- [repos/frontend/CLAUDE.md](repos/frontend/CLAUDE.md) — same for the
  frontend.
