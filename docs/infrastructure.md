# Infrastructure — AniChan (anichan.net)

Product: **AniChan** — `anichan.net`. Repos use the `anime-engine-*` prefix.

Deploy target is a vast.ai box shared with the goongle data stores. All services
run as Docker containers on the external Docker network **`goongle-network`**, so
they reach each other by container name. The host publishes internal ports which
vast.ai maps to public ports.

## Server

| | |
|---|---|
| SSH | `vast-canada-2` → `root@70.30.158.46:43730` (key auth) |
| Docker | 28.5.2, 19 cores, ~1.2 TB free |
| Network | `goongle-network` (external bridge) |

## vast.ai public port map (internal → public)

| internal | public | used by |
|---|---|---|
| 22 | 70.30.158.46:**43730** | SSH |
| 6333–6335 | 43262 / 43788 / 43617 | Qdrant (goongle) |
| 8000 | 43064 | free |
| 8001 | 43794 | free |
| 8002 | 43829 | **MongoDB** (→27017) |
| 8003 | **43879** | **anime frontend** (→3000) |
| 8004 | 43458 | free |
| 8005 | 43505 | **Elasticsearch** (→9200) |
| 8006 | 43525 | Kibana (→5601) |
| 8007 | 43270 | goongle dev-frontend (→3000) |
| 8008 | **43577** | **anime backend** (→8000) |

## Data stores (on `goongle-network`)

| Service | Internal | Public | Auth |
|---|---|---|---|
| MongoDB 8.0 | `mongodb:27017` | 70.30.158.46:43829 | `admin` / `<stored in control .env on the server>`, db `rfp_db` (use a new `anime_db`) |
| Elasticsearch 8.13 | `elasticsearch:9200` | 70.30.158.46:43505 | `elastic` / `<stored in control .env on the server>` |
| Kibana | `kibana:5601` | 70.30.158.46:43525 | via ES |
| Qdrant | `qdrant:6333` | 70.30.158.46:43262 | goongle (not used here) |

## anime-engine services

| Service | Container | Internal port | Host port | Public URL |
|---|---|---|---|---|
| backend (FastAPI) | `anime-backend` | 8000 | 8008 | http://70.30.158.46:43577 |
| frontend (Next.js) | `anime-frontend` | 3000 | 8003 | http://70.30.158.46:43879 |

- Frontend SSR → backend via `http://anime-backend:8000` (container network).
- Browser → backend via `NEXT_PUBLIC_BACKEND_URL=http://70.30.158.46:43577` (baked at image build).
- Deploy dirs on server: `/home/anime/frontend`, `/home/anime/backend` (each has `docker-compose.yml` + `.env`).

## Repos

| Folder | Repo |
|---|---|
| `frontend/` | `David-search/anime-engine-frontend` |
| `backend/` | `David-search/anime-engine-backend` |
| `claude/` (control) | `David-search/anime-engine-control` |

## Integration (when wiring social/search)

- **MongoDB** (users, comments, likes, watch-history): `MONGO_URI=mongodb://admin:<stored in control .env on the server>@mongodb:27017/anime_db?authSource=admin`
- **Elasticsearch** (search): `ELASTIC_URL=http://elasticsearch:9200`, `ELASTIC_USER=elastic`, `ELASTIC_PASSWORD=<stored in control .env on the server>`, index `anime`.

Currently the UI for auth/comments/likes is stubbed (localStorage / local state) and search uses AniList; swap these to Mongo/ES via the env above.
