# backend — catalog / search / detail / auth / social API

FastAPI service (Python 3.12) serving the AniChan API. Container
`anime-backend`, host port `8008 → container 8000`, public
`http://70.30.158.46:43577`. The request path is **pure Mongo + ES
reads** — it never calls AniList at request time, with one cached
exception (`/catalog/trending`, below). AniList is touched only by the
offline ingest CLI in `scripts/`.

## App layout

`app/` is the web layer; everything else under it is shared libs. The
running app **never imports** `scripts/` — that's the ingest CLI and
lives apart on purpose.

```
app/
  main.py            # FastAPI app, CORS, lifespan (Mongo/ES clients), router includes
  routers/
    catalog.py       # /api/catalog/* — list, by-id, trending, popular, airing, browse, genres
    search.py        # /api/search, /api/suggest — search-as-you-type + faceted query
    auth.py          # /api/auth/* — email signup/login + Google verify, JWT issue
    social.py        # /api/social/* — comments, likes, watch history (per-user)
  anilist.py         # AniList GraphQL client (trending cache + shared by ingest)
  es.py              # Elasticsearch client + query builders, facet aggs
  db.py              # Mongo (Motor) client + collection accessors
  config.py          # settings (env-driven): MONGO_URI, ELASTIC_*, GOOGLE_CLIENT_ID, JWT
  auth.py            # password hashing, JWT encode/verify, Google id-token verify, deps
scripts/
  ingest.py          # standalone AniList → Mongo → ES ingest CLI (NOT imported by app)
```

## Routes

`app/main.py` includes one router per domain.

| Prefix      | Router                                       | What it serves                                                       |
|-------------|----------------------------------------------|---------------------------------------------------------------------|
| `/api/catalog` | [app/routers/catalog.py](app/routers/catalog.py) | List + by-id + popular + airing + browse + genres from Mongo; `trending` from cached AniList |
| `/api/search`  | [app/routers/search.py](app/routers/search.py)   | Search-as-you-type suggest + faceted full query against ES `anime`  |
| `/api/auth`    | [app/routers/auth.py](app/routers/auth.py)       | Email signup/login + Google sign-in verify; issues a JWT            |
| `/api/social`  | [app/routers/social.py](app/routers/social.py)   | Comments, likes, watch history — all keyed by the JWT user          |

`GET /health` (in `main.py`) is the deploy probe — returns `200` once
the Mongo + ES clients are up.

### Catalog reads (Mongo)

`/catalog` reads `anime_db.anime`. The catalog id **is** the AniList id;
`idMal` is carried for host mapping. List endpoints paginate over Mongo;
the single-anime endpoint returns the full doc including the heavy fields
(relations / characters / staff / recommendations / reviews) populated by
ingest `enrich`.

### Search (ES)

`/search` queries the ES `anime` index — `search_as_you_type` for the
suggest dropdown, plus a faceted full query exposing `genres` / `tags` /
`source` / `season` facets and multilingual title search across
`title.en` + `title.romaji` + `title.native`. The query builders live in
[app/es.py](app/es.py); the index mapping is created by ingest, not the app.

### Trending — the one AniList passthrough

`/catalog/trending` is the **only** request-path AniList call. It mirrors
AniList `TRENDING_DESC` via [app/anilist.py](app/anilist.py) and caches the
result **in-process for 30 minutes**. Everything else on the request path
is Mongo/ES. (MAL/Jikan + TMDB are possible **future** enrichment, not
wired.)

### Auth & social

`/auth` supports **email** (signup/login with hashed passwords) and
**Google** (verify the Google id token against `GOOGLE_CLIENT_ID`), then
issues a JWT. `/social` endpoints require that JWT and read/write the
`users` / `comments` / `likes` / `history` collections in `anime_db`.

## Run locally — native, not docker

The synced `work/backend/.env` uses **in-network** hostnames
(`mongodb://…@mongodb:27017`, `http://elasticsearch:9200`) that only
resolve inside `goongle-network` on the server. From a laptop, override
`MONGO_URI` / `ELASTIC_URL` to the **external** addresses
(`70.30.158.46:43829`, `70.30.158.46:43505`) first, then:

```bash
pip install -r requirements.txt
python -m uvicorn app.main:app --reload --port 8000
# probe it:
curl -sS http://localhost:8000/health
curl -sS 'http://localhost:8000/api/catalog/trending'
curl -sS 'http://localhost:8000/api/search?q=naruto'
```

Don't `docker compose up` from a laptop — the in-network URLs won't
resolve there. See the control-repo `CLAUDE.md` "Running a service
locally" note.

## Data pipeline (`scripts/ingest.py`)

A standalone CLI, **not** imported by the running app. It's the **only**
AniList caller in the repo, paced at ~2.2s/req because AniList caps
offset pagination at 5000 entries and degrades to ~30 req/min. It writes
the catalog into Mongo `anime_db.anime` and indexes searchable docs into
ES `anime` (including creating the ES mapping).

| Mode                  | What it does                                                                                                  |
|-----------------------|--------------------------------------------------------------------------------------------------------------|
| `full`                | popularity sweep + per-`startDate`-year slices                                                                |
| `years [from] [to]`   | ingest a year range                                                                                           |
| `popular [pages]`     | ingest top-popularity pages                                                                                   |
| `enrich [limit]`      | per-anime heavy fields (relations / characters / staff / recommendations / reviews); idempotent catch-up — only touches docs **missing the `characters` field** |
| `sample [n]`          | small smoke sample                                                                                            |

Run on the server (the ingest deps + network egress live in the
container):

```bash
docker exec anime-backend python -m scripts.ingest <mode>
```

`/ingest <mode>` wraps this over SSH. Because `enrich` is idempotent
(only touches docs without `characters`), re-running it is the catch-up
path after a fresh `full`/`years`/`popular` pass.

## Deploy — build on server

There is **no self-hosted runner and no `dev` branch**. The primary path
is build-on-server: sync `work/backend/` up to `/home/anime/backend/`
over `vast-canada-2`, then rebuild from the on-server compose (which has
`build: .` and reads `/home/anime/backend/.env`):

```bash
ssh vast-canada-2 'cd /home/anime/backend && docker compose up -d --build'
curl -fsS http://70.30.158.46:43577/health
```

`/deploy-backend` drives this end-to-end (sync → build → verify
`/health`). The on-server `/home/anime/backend/.env` is the **runtime
source of truth** — it is NOT in the repo. There's a CI/CD alt
(`.github/workflows/ci-cd.yml`, push `main` → Actions build → scp image →
`docker load` + compose up) but it **fails** until the repo owner adds
the `SERVER_SSH_KEY` Actions secret. Use build-on-server until then.

## Infrastructure (read access)

The data stores are **shared with a separate goongle project**; AniChan
uses its own db (`anime_db`) and index (`anime`). Never restart,
recreate, or reconfigure `mongodb` / `elasticsearch`, and never drop a
collection or index without explicit confirmation.

| Service        | On the server (in-network)   | From outside (host `70.30.158.46`)   | Auth                                                            |
|----------------|------------------------------|--------------------------------------|----------------------------------------------------------------|
| MongoDB        | `mongodb://mongodb:27017`    | `mongodb://70.30.158.46:43829`       | `admin:<stored in control .env on the server>`, db `anime_db`  |
| Elasticsearch  | `http://elasticsearch:9200`  | `http://70.30.158.46:43505`          | `elastic:<stored in control .env on the server>`, index `anime`|
| Backend        | `http://anime-backend:8000`  | `http://70.30.158.46:43577`          | none                                                           |

`anime_db` collections: `anime` (catalog), `users`, `comments`, `likes`,
`history`. ES index `anime`: `search_as_you_type` suggest;
`genres`/`tags`/`source`/`season` facets; multilingual title search
(`en` + `romaji` + `native`).

### Probes (run on-server)

```bash
# Elasticsearch — count, indices, mapping
curl -sS -u "elastic:$ELASTIC_PASSWORD" 'http://localhost:8005/anime/_count'
curl -sS -u "elastic:$ELASTIC_PASSWORD" 'http://localhost:8005/_cat/indices?v&h=index,docs.count,store.size'
curl -sS -u "elastic:$ELASTIC_PASSWORD" 'http://localhost:8005/anime/_mapping' | python3 -m json.tool | head -40

# MongoDB — collections + a sample catalog doc
mongosh "$MONGO_URI" --eval 'show collections'
mongosh "$MONGO_URI" --eval 'db.anime.findOne({}, {title:1, genres:1, idMal:1})'

# Backend — request round-trips
curl -sS http://localhost:8008/health
curl -sS 'http://localhost:8008/api/catalog/trending'
curl -sS 'http://localhost:8008/api/search?q=naruto'
```

### Probes (off-server)

Same commands, substituting the external addresses: ES
`http://70.30.158.46:43505`, Mongo `mongodb://…@70.30.158.46:43829`,
backend `http://70.30.158.46:43577`.

## Common gotchas

- **`anime` ES index + `anime_db` Mongo are shared infra.** Don't
  recreate the index casually — ingest owns its mapping. The data stores
  are co-tenant with goongle; a careless `mongodb`/`elasticsearch`
  restart hits both projects. Scope the blast radius before anything
  destructive.
- **The app never calls AniList at request time — except `trending`.**
  If you see request-path latency spikes, it's Mongo/ES, not AniList.
  The one exception is `/catalog/trending` (30-min in-process cache); a
  cold cache is the only place an inbound request waits on
  `graphql.anilist.co`.
- **Ingest is paced and rate-limited.** ~2.2s/req, offset cap 5000,
  ~30 req/min when degraded. A `full` run is long-running — run it
  inside the container (`docker exec`), not from a laptop, so it survives
  your SSH session.
- **`enrich` only touches docs missing `characters`.** That's the
  idempotency contract — it's the catch-up pass, safe to re-run. If you
  change which heavy fields enrich writes, the "missing `characters`"
  gate is what decides what gets re-fetched.
- **The catalog id is the AniList id.** Don't introduce a separate
  primary key; `idMal` rides along for host mapping but `_id` / the
  catalog id is the AniList id.
- **Code is `COPY`'d at Docker-build time — no bind mount.** `docker
  restart anime-backend` will NOT pick up edits; you must
  `docker compose up -d --build`. `/deploy-backend` does this.
