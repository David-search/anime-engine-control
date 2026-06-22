---
description: Summon the AniChan cross-service architecture overview
---

`/architecture`

Read [.claude/guides/architecture.md](.claude/guides/architecture.md) and the
**System diagram** in [CLAUDE.md](CLAUDE.md), then give the user a concise
walkthrough of how AniChan fits together:

- **Catalog source → store.** AniList GraphQL → `scripts/ingest.py` (the only
  AniList caller, paced ~2.2s/req) → upserts into Mongo `anime_db.anime` +
  indexes into ES `anime`.
- **Backend (FastAPI, `anime-backend`).** Serves catalog / search / detail /
  browse / auth / social **purely from Mongo + ES** — no AniList on the request
  path, with the single cached exception `/catalog/trending` (mirrors AniList
  `TRENDING_DESC`, 30-min in-process cache).
- **Frontend (Next.js 15, `anime-frontend`).** AniList-style filter UI on
  `/search`, rich detail page on `/anime/[id]`, MegaPlay iframe player on
  `/watch/[id]/[ep]`. Auth via email/password + Google GIS.
- **One host** (`vast-canada-2`), Mongo + ES **shared with goongle** (AniChan
  owns only `anime_db` / the `anime` index).

Tailor depth to what the user asked — default to a short orientation, not a
full dump. For the per-service internals, point at
[repos/backend/CLAUDE.md](repos/backend/CLAUDE.md) and
[repos/frontend/CLAUDE.md](repos/frontend/CLAUDE.md).
