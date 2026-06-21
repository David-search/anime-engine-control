# anime-engine-control (AniChan)

Control plane for **AniChan** (`anichan.net`): research, infra map, deploy notes,
and Claude config. No application code lives here — that's in the two service repos.

| Folder / Repo | What |
|---|---|
| `David-search/anime-engine-frontend` | Next.js 15 UI (catalog, watch, social UI) |
| `David-search/anime-engine-backend` | FastAPI (AniList catalog, server resolution, m3u8 proxy) |
| `David-search/anime-engine-control` | this repo — docs + research + Claude config |

## Docs

- [`docs/infrastructure.md`](docs/infrastructure.md) — server, ports, Mongo/ES, deploy map
- [`BUILD-PLAN.md`](BUILD-PLAN.md) — architecture & phased build
- [`research/`](research/) — how anime streaming sites work, host integration, costs, pitfalls

## Stack

- **Catalog**: AniList GraphQL (browse/search/genres). MAL id (`idMal`) carried for host mapping.
- **Video**: embed third-party host players (default **MegaPlay**, AniList-keyed).
- **Data (server)**: MongoDB (`mongodb:27017`) + Elasticsearch (`elasticsearch:9200`) on `goongle-network`.
- **Deploy**: vast-canada-2 (`root@70.30.158.46:43730`), Docker, per-repo GitHub Actions CI/CD.

## Run locally

```bash
docker network create goongle-network        # once (shared bridge)

cd backend  && cp .env.example .env  && docker compose up -d --build   # :8000
cd frontend && cp .env.example .env  && docker compose up -d --build   # :3000
```

Open http://localhost:3000. Or run natively:

```bash
cd backend  && python3.12 -m venv .venv && ./.venv/bin/pip install -r requirements.txt
            && ./.venv/bin/uvicorn app.main:app --reload --port 8000
cd frontend && npm install && npm run dev
```

## Deploy

Per-repo GitHub Actions (`.github/workflows/ci-cd.yml`): push to `main` →
build image → `docker save | gzip` → scp to server → `docker load` + `compose up`.

Required GitHub secrets:
- both repos: `SERVER_SSH_KEY` (private key for `root@70.30.158.46:43730`)
- frontend repo: `NEXT_PUBLIC_BACKEND_URL` = `http://70.30.158.46:43577`

Server deploy dirs: `/home/anime/frontend`, `/home/anime/backend` (each holds
`docker-compose.yml` + `.env`). Network `goongle-network` already exists.

## Roadmap (next phase)

- Auth: Google + email/password → MongoDB users
- Ingest: AniList → MongoDB (full anime metadata) → index to Elasticsearch
- Search: ES-powered autosuggestion (replace AniList live search)
- Wire comments / likes / watch-history to MongoDB
