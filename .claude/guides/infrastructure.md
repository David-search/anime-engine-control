# Infrastructure — addresses, ports, credentials


One host. Both AniChan services + the shared data stores run as Docker
containers on it, on the external docker network **`goongle-network`**,
so they reach each other by container name. The host publishes internal
ports which vast.ai maps to public ports on `70.30.158.46`.

- **vast-canada-2** (`70.30.158.46`, ssh alias `vast-canada-2`) — the
  one and only AniChan host. Runs `anime-frontend` + `anime-backend`,
  and shares `mongodb` / `elasticsearch` (and the goongle project's own
  containers) on the same docker network.

Use the **container name** (e.g. `mongodb:27017`) when on the same
docker network as the target; the **external public** port from anywhere
else.

## Port map — host → external public on `70.30.158.46`

| Service        | Container        | Inner port              | Host port | External (`70.30.158.46`) |
|----------------|------------------|-------------------------|-----------|---------------------------|
| backend        | `anime-backend`  | 8000                    | 8008      | **43577**                 |
| frontend       | `anime-frontend` | 3000                    | 8003      | **43879**                 |
| MongoDB        | `mongodb`        | 27017 (mapped to `:8002`)| 8002     | **43829**                 |
| Elasticsearch  | `elasticsearch`  | 9200 (mapped to `:8005`)| 8005      | **43505**                 |
| SSH            | host             | 22                      | —         | **43730**                 |

Public service URLs:

- backend  — `http://70.30.158.46:43577`
- frontend — `http://70.30.158.46:43879`

The frontend reaches the backend two ways:

- **SSR (server→server, in-network):** `http://anime-backend:8000`
- **Browser (client→public):** `NEXT_PUBLIC_BACKEND_URL=http://70.30.158.46:43577`
  — baked into the image at **build** time (it's a `NEXT_PUBLIC_*` var).

## Shared infra — MongoDB + Elasticsearch

Same host, shared with a separate goongle project. AniChan uses its
**own** db (`anime_db`) and **own** index (`anime`); it does NOT touch
goongle's `rfp_db` or other indices. See [safety.md](safety.md).

| Service          | Container       | In-network        | External            | Auth                                          | AniChan uses        |
|------------------|-----------------|-------------------|---------------------|-----------------------------------------------|---------------------|
| MongoDB          | `mongodb`       | `mongodb:27017`   | `70.30.158.46:43829`| `admin` / `<stored in control .env on the server>` | db `anime_db`       |
| Elasticsearch 8.13 | `elasticsearch` | `elasticsearch:9200` | `70.30.158.46:43505`| `elastic` / `<stored in control .env on the server>` | index `anime`       |

**MongoDB `anime_db`** collections: `anime` (catalog), `users`,
`comments`, `likes`, `history`.

**Elasticsearch `anime` index**: `search_as_you_type` suggest;
genres / tags / source / season facets; multilingual title search
(en + romaji + native).

In-network connection strings (what the on-server `.env` uses):

```
MONGO_URI=mongodb://admin:<stored in control .env on the server>@mongodb:27017/anime_db?authSource=admin
ELASTIC_URL=http://elasticsearch:9200
ELASTIC_USER=elastic
ELASTIC_PASSWORD=<stored in control .env on the server>
ELASTIC_INDEX=anime
```

## Credentials

- Mongo: `admin` / `<stored in control .env on the server>`, db `anime_db`
- Elasticsearch basic auth: `elastic` / `<stored in control .env on the server>`
- Backend / Frontend: no auth on the service itself (end-user auth is
  app-level, in `anime_db.users`)

The real Mongo/ES passwords live ONLY in the on-server control `.env`.
Never write them into a committed file — use the literal placeholder
`<stored in control .env on the server>`. See [secrets.md](secrets.md).

## Quick probes (off-server)

```bash
set -a && source .env && set +a

# ES doc count (the AniChan index only)
curl -sS -u "$ELASTIC_USER:$ELASTIC_PASSWORD" "$ELASTIC_URL/anime/_count"

# Mongo ping + catalog count
mongosh "$MONGO_URI" --eval 'db.adminCommand({ping:1}); db.anime.countDocuments()'

# Backend health + a real catalog read
curl -sS "http://70.30.158.46:43577/catalog/trending"
curl -sS "http://70.30.158.46:43577/api/search?q=frieren"

# Frontend up
curl -sS -o /dev/null -w '%{http_code}\n' "http://70.30.158.46:43879"
```

(Off-server probes use the **external** ports `43829` / `43505`; the
`$ELASTIC_URL` / `$MONGO_URI` in the control `.env` should point at
those public addresses, not the in-network names.)

## SSH

```bash
ssh -p 43730 root@70.30.158.46     # alias: vast-canada-2
```

Lands at `/root`. On-server deploy dirs:

- `/home/anime/backend/`  — Dockerfile, `docker-compose.yml` (with `build: .`), `.env`
- `/home/anime/frontend/` — Dockerfile, `docker-compose.yml` (with `build: .`), `.env`

Each `.env` is the **source of truth** for that service's runtime config.
See [deploy-loop.md](deploy-loop.md).
