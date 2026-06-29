# backend — catalog / search / detail / auth / social API

FastAPI service (Python 3.12) serving the AniChan API. Container
`anime-backend`, host port `8008 → container 8000`; reached publicly as
`https://anichan.net/api/*` through the **web-goongle nginx edge** (origin
`http://70.30.158.46:43577`). **Every route is mounted under `/api`** (see
`main.py`). The catalog/search path is **pure Mongo + ES reads** (it never
calls AniList at request time, except the cached `/api/catalog/trending`);
the **`/api/watch/*`** path additionally resolves streams via the Miruro pipe
+ the self-host origin (below). AniList is otherwise touched only by the
offline ingest CLI in `scripts/`.

## App layout

`app/` is the web layer; everything else under it is shared libs. The
running app **never imports** `scripts/` — that's the ingest CLI and
lives apart on purpose.

```
app/
  main.py            # FastAPI app, CORS, lifespan (Mongo/ES clients), routers mounted under /api
  routers/
    catalog.py       # /api/catalog/* — trending, popular, airing, browse, genres, search, sitemap, anime/{id}
    search.py        # /api/search, /api/suggest — search-as-you-type + faceted query
    auth.py          # /api/auth/* — register, login, google, me (JWT)
    social.py        # /api/{comments,likes,history,watchlist,lists,...} — flat per-user (NOT /api/social)
    watch.py         # /api/watch/* — stream resolution + HLS/subtitle proxy + self-host (below)
  sources.py         # stream resolver: Miruro secure-pipe + curated hosts + self-host Source 1
  anilist.py         # AniList GraphQL client (trending cache + shared by ingest)
  es.py              # Elasticsearch client + query builders, facet aggs
  db.py              # Mongo (Motor) client; ensure_indexes() for all 9 collections
  config.py          # settings (env): MONGO_URI, ELASTIC_*, GOOGLE_CLIENT_ID, JWT_*, SELFHOST_*, TELEGRAM_*
  auth.py            # password hashing, JWT encode/verify, Google id-token verify, deps
  telegram_logger.py # ships WARN/ERROR logs to a Telegram channel when TELEGRAM_* set (optional)
scripts/
  ingest.py          # standalone AniList → Mongo → ES ingest CLI (NOT imported by app)
selfhost/            # build-farm scripts mirrored from claude/self-hosted (resolve/download/encode/ship)
```

## Routes

`app/main.py` includes one router per domain.

| Prefix      | Router                                       | What it serves                                                       |
|-------------|----------------------------------------------|---------------------------------------------------------------------|
| `/api/catalog` | [app/routers/catalog.py](app/routers/catalog.py) | trending (cached AniList) + popular/airing/browse/genres/search/sitemap + `anime/{id}` from Mongo |
| `/api/search`  | [app/routers/search.py](app/routers/search.py)   | Search-as-you-type suggest + faceted full query against ES `anime`  |
| `/api/auth`    | [app/routers/auth.py](app/routers/auth.py)       | register / login / google / me — email+password or Google, issues a JWT |
| `/api/*` social | [app/routers/social.py](app/routers/social.py)  | flat: `/api/comments` `/api/likes` `/api/history` `/api/watchlist[/contains]` `/api/lists[...]` — JWT-keyed (**no** `/api/social` prefix) |
| `/api/watch`   | [app/routers/watch.py](app/routers/watch.py)     | stream resolution (`/episodes` `/servers` `/sources`) + HLS/subtitle proxy (`/m3u8` `/seg` `/vtt`) + self-host `cache-state` |

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

`/api/catalog/trending` is the **only** request-path AniList call. It mirrors
AniList `TRENDING_DESC` via [app/anilist.py](app/anilist.py) and caches the
result **in-process for 30 minutes**. Everything else on the request path
is Mongo/ES. (MAL/Jikan + TMDB are possible **future** enrichment, not
wired.)

### Streaming & self-host (`/api/watch`)

The heart of the app — [app/routers/watch.py](app/routers/watch.py) +
[app/sources.py](app/sources.py):

- **Resolver (`sources.py`).** Streams come from the **Miruro aggregator
  "secure pipe"** (`/api/secure/pipe?e=base64url(json)`; bases rotate
  `.bz/.to/.tv/.ru`). Miruro's rotating provider codenames are abstracted to
  stable `source1..N` keyed on the **host**. Curated reliable hosts:
  `animedao`/`anidbapp`/`animegg` (clean, proxied) then `allmanga`/`anikoto`
  (embed iframes). A global semaphore + TTL caches (episodes 10 min, servers
  3 min) keep it from bursting Miruro into a 429.
- **Self-host Source 1.** When `SELFHOST_CACHE=1` and the episode exists at
  `SELFHOST_ORIGIN/{anilistId}/{ep}/sub/master.m3u8`, it's returned as **Source 1
  "AniChan · self-hosted (ad-free)"**, ahead of Miruro. One multi-audio HLS build
  per episode (JP + any dub as EXT-X-MEDIA audio); subtitles prefer
  `subs/tracks.json` (styled ASS + embedded fonts for JASSUB), else master VTT.
  Resolved **concurrently** with Miruro (separate 60s/15s cache) so a freshly
  cached episode surfaces within seconds.
- **Proxy (`watch.py`).** `/api/watch/m3u8` rewrites playlists to root-relative
  proxy URLs (and strips in-manifest subtitle groups so the selector can't
  desync); `/api/watch/seg` streams segments/keys Range-aware; `/api/watch/vtt`
  serves subtitles (stream-referer → miruro → none). Proxied with the per-host
  Referer/Origin the CDN needs, so **the origin IP never reaches the browser**;
  an **SSRF guard** rejects private/loopback/link-local/reserved/metadata IPs.
- **CDN direct-serve + token auth (`_emit`/`_sign`, since 2026-06-29).** When
  `SELFHOST_CDN_BASE` is set, the self-host source serves heavy bytes
  (segments/subtitles/fonts) **direct from Bunny `cdn.anichan.net`**, token-signed
  (`_sign` = `sha256_b64url(SELFHOST_CDN_TOKEN_KEY + path + expires)`, TTL
  `SELFHOST_CDN_TTL`); playlists keep proxying so their child URLs get rewritten +
  signed. Miruro/no-CDN fall back to the proxy. Full design + anti-scrape model:
  [claude/self-hosted/19-cdn-token-auth-and-hardening.md](../../self-hosted/19-cdn-token-auth-and-hardening.md).
- **Coverage callback.** `POST /api/watch/cache-state` (auth: `SELFHOST_INGEST_TOKEN`)
  is how a build-farm node reports which eps are cached → **merges** into
  `selfhost_cache` (never regresses a partial run; fills `total_eps` from the catalog)
  for the coverage badges. The on-open `trigger_ingest` → `SELFHOST_INGEST_URL` auto-cache
  path is **disabled on the server (2026-06-26)** — caching is now a deliberate build-farm
  step, not viewer-triggered (the env var is retained but the call is commented out). Farm
  ops: [claude/self-hosted/RUNBOOK.md](../../self-hosted/RUNBOOK.md).

### Auth & social

`/api/auth` supports **email** (register/login with hashed passwords) and
**Google** (verify the id token against `GOOGLE_CLIENT_ID`), then issues a JWT
(`JWT_SECRET`, `JWT_TTL_DAYS`). The social routes are **flat under `/api`** (not
`/api/social`) and JWT-keyed: `/api/comments` (per-anime), `/api/likes`,
`/api/history` (resume), `/api/watchlist` ("My List"), and `/api/lists`
(+ `/api/lists/public`, `/api/lists/{id}/{items,reorder,rate}`) for public
**tops** / private **collections**. They read/write `users` / `comments` /
`likes` / `history` / `watchlist` / `lists` / `list_ratings` in `anime_db`.

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

`anime_db` collections (9): `anime` (catalog) · `users` · `comments` · `likes` ·
`history` · `watchlist` ("My List") · `lists` (public tops / private collections) ·
`list_ratings` · `selfhost_cache` (self-host coverage marks). ES index `anime`:
`search_as_you_type` suggest;
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
  The one exception is `/api/catalog/trending` (30-min in-process cache); a
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
