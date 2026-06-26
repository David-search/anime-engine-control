# anime-engine-control — orchestration plane

This repo is **docs + Claude config**, not source. Cloned anywhere with
a populated `.env`, it gives a fresh Claude session everything needed to
inspect, edit, test, and deploy the AniChan stack — over SSH and HTTP,
against a single physical host:

- **vast-canada-2** (`70.30.158.46`, ssh alias `vast-canada-2`,
  port `43730`) — the only host. Runs both AniChan containers
  (`anime-frontend`, `anime-backend`) plus the shared data stores
  (`mongodb`, `elasticsearch`), all on the external Docker network
  `goongle-network`. The data stores are shared with a separate
  goongle project; AniChan uses its **own** Mongo database (`anime_db`)
  and ES index (`anime`), never goongle's.

**One host, two services, no Qdrant.** AniChan is a HiAnime-style anime
catalog + streaming site (planned domain `anichan.net`). There's no
embedder, no vector DB, no image/face search — the backend request path
is pure Mongo/ES reads. Anything that mentions Qdrant, embedder,
faces, image-search, a `dev` branch, or a self-hosted runner is
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
2. Render the **System diagram** below verbatim (the box-drawing block).
3. Summarise the `work/` state from the SessionStart banner — present
   clones with branch + sha, missing ones with the suggested
   `/setup-all` or `/work-on <service>`.
4. Note anything unusual in the banner ("behind origin/main by N",
   missing repos, etc.) so the user can decide whether to fast-forward.
5. Then proceed with whatever they asked for.

Keep the greeting short — the diagram + state summary is the
substantive part. Don't include the diagram on subsequent turns.

## System diagram

```
                              USERS (browser)
                                    │
                                    ▼
                       ┌──────────────────────────┐
                       │   frontend (Next.js 15)  │   anime-engine-frontend
                       │   container anime-frontend│   single main branch
                       │   host :8003 → :3000     │   public :43879
                       └────────────┬─────────────┘
                                    │
                       catalog / search / detail / watch
                       GET /catalog  GET /search  GET /anime/:id
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
            │  │ anime (catalog)││   │  │ search_as_you_   ││
            │  │ users          ││   │  │  type suggest    ││
            │  │ comments       ││   │  │ genre/tag/source/││
            │  │ likes          ││   │  │  season facets   ││
            │  │ history        ││   │  │ title en+romaji  ││
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

**Per-request flows**

Catalog / detail:
```
frontend → backend
backend → Mongo anime_db.anime   (catalog list / single anime read)
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
frontend → backend /catalog/trending
backend → AniList TRENDING_DESC  (in-process cache, 30 min TTL)
backend ← list → frontend
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

One host, one port table. From this repo (any machine), use
`<external>`. From on the server, use `localhost:<host>` or the
in-network container name.

### vast-canada-2 (`70.30.158.46`) — the only host

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

**Public URLs**

| | |
|---|---|
| Frontend | `http://70.30.158.46:43879` (planned `anichan.net`) |
| Backend  | `http://70.30.158.46:43577` |

The frontend bakes `NEXT_PUBLIC_BACKEND_URL=http://70.30.158.46:43577`
at image-build time so the browser reaches the backend directly; SSR
inside the container reaches it in-network as `http://anime-backend:8000`.

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
`/catalog/trending` mirrors AniList `TRENDING_DESC`, cached in-process
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

- [.claude/guides/infrastructure.md](.claude/guides/infrastructure.md) — host, port table,
  addresses, credentials, data stores.
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
