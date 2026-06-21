# AniChan — Claude context

**Product:** AniChan (`anichan.net`). **Repos:** `David-search/anime-engine-{frontend,backend,control}`.

## Architecture
- **Catalog id = AniList id** (primary). AniList GraphQL provides titles/genres/score/
  banner/etc. and `idMal` (kept for host mapping). Ingested into MongoDB, indexed to ES.
- **Frontend** (Next.js 15): home (hero+rows), genres, search (ES autosuggest), detail,
  watch (single default host = MegaPlay iframe), auth/comments/likes UI.
- **Backend** (FastAPI): AniList catalog, server resolution (`/api/servers`), m3u8 proxy,
  + (this phase) Mongo data layer, AniList ingest, ES search/suggest, auth.
- **Video**: embed third-party host players (default MegaPlay, AniList-keyed). Hosts gate
  their CDNs; we embed, not rip. See research/host-integration-findings.md.

## Infra (see docs/infrastructure.md)
- Server: `root@70.30.158.46:43730` (vast-canada-2), Docker, network `goongle-network`.
- Mongo: `mongodb:27017` (public 43829), `admin/<stored in control .env on the server>`, db `anime_db`.
- Elastic: `elasticsearch:9200` (public 43505), `elastic/<stored in control .env on the server>`, index `anime`.
- anime backend: internal 8000 → host 8008 → public 43577.
- anime frontend: internal 3000 → host 8003 → public 43879.
- Local dev reaches Mongo/ES via public ports (43829/43505); on-server via container names.

## Deploy
Per-repo GitHub Actions on push to `main`: build → `docker save|gzip` → scp → `docker load`
+ `docker compose up -d --no-build`. Secrets: `SERVER_SSH_KEY` (both), `NEXT_PUBLIC_BACKEND_URL`
(frontend = http://70.30.158.46:43577). Deploy dirs `/home/anime/{frontend,backend}`.

## Status / roadmap
- ✅ Catalog (AniList), genres, watch (MegaPlay), social UI (stubbed), Docker, CI/CD.
- ⏳ This phase: Mongo + AniList ingest + ES autosuggest + auth (Google/email) + wire social.
