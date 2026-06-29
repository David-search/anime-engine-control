# Architecture overview

This file is the cross-service map. For the build-out plan and phase
detail, read [BUILD-PLAN.md](../../BUILD-PLAN.md); for the AniList host
research, [research/host-integration-findings.md](../../research/host-integration-findings.md).

## What is AniChan

A HiAnime-style anime catalog + streaming site, **live at https://anichan.net**
(via the web-goongle nginx TLS edge). Users hit the frontend, browse or search
the catalog, open a rich detail page (characters / staff / relations /
recommendations), and stream in the in-house **hls.js + JASSUB** player. Stream
sources are resolved by the backend `/api/watch/*` path: the **Miruro** aggregator
pipe (curated hosts) plus the **self-hosted** tier — *★ AniChan*, Source 1 — served
from the **Bunny CDN** (`cdn.anichan.net`, token-signed) backed by the offshore HLS
origin and a 6-node build farm. Full serving design:
[../../self-hosted/19-cdn-token-auth-and-hardening.md](../../self-hosted/19-cdn-token-auth-and-hardening.md).

There is one read path and one write path:

- **Catalog ingest (write)** — `scripts/ingest.py` in the backend repo
  pulls from AniList GraphQL (`https://graphql.anilist.co`), normalises
  each entry, upserts it into MongoDB `anime_db.anime`, and indexes it
  into the Elasticsearch `anime` index. This is a standalone CLI, **not**
  imported by the running app.
- **Serving (read)** — the FastAPI `backend` serves catalog / search /
  detail / browse / trending + auth + social entirely from Mongo / ES.
  AniList is **not** in the request path, with one cached exception:
  `/api/catalog/trending` mirrors AniList `TRENDING_DESC`, cached in-process
  for 30 min.

The frontend is an AniList-style filtered browse UI plus a rich detail
page and an **hls.js + JASSUB** watch panel (self-host Source 1 +
Miruro-resolved hosts). Auth is email/password + Google.

## What backs each capability

| Capability                       | Backed by                                                            |
|----------------------------------|---------------------------------------------------------------------|
| Search + autosuggest             | Elasticsearch `anime` index (search_as_you_type suggest)            |
| Catalog / detail / browse        | MongoDB `anime_db.anime`                                            |
| Trending (only cached AniList)   | AniList `TRENDING_DESC`, 30-min in-process cache                     |
| Auth (email/password + Google)   | MongoDB `anime_db.users`                                            |
| Social (comments/likes/history/watchlist/lists) | MongoDB `anime_db.{comments,likes,history,watchlist,lists,list_ratings}` |
| Playback (streaming)             | `/api/watch/*`: Miruro secure-pipe (curated hosts) + **self-host Source 1** → Bunny CDN (`cdn.anichan.net`, token-signed) ← offshore origin ← 6-node build farm |

The live API never calls AniList per-request (except the cached trending
endpoint). The catalog is fully materialised in Mongo + ES by the ingest
job, so request-path latency is pure Mongo/ES.

## Repos & containers

| Repo                                  | Branches | Container        |
|---------------------------------------|----------|------------------|
| `David-search/anime-engine-backend`   | main     | `anime-backend`  |
| `David-search/anime-engine-frontend`  | main     | `anime-frontend` |
| `David-search/anime-engine-control`   | main     | *(docs/config only — no container)* |

There is a single `main` branch per repo — **no `dev` branch**, no
prod/dev container split. Both service containers run on the external
docker network `goongle-network`. The control repo
(`/Users/admin/Documents/anime/claude`) is DOCS + CLAUDE config only,
no source.

## Data layers

- **MongoDB `anime_db`** (container `mongodb`, in-net `mongodb:27017`):
  the source of truth for the running app. Collections:
  - `anime` — the catalog. One doc per AniList id (the primary key),
    with `idMal` retained for host mapping. Holds titles (en + romaji +
    native), genres, tags, score, season, source, banner/cover art, and
    the heavy enrichment fields (relations, characters, staff,
    recommendations, reviews) for entries that have been enriched.
  - `users` — auth (email/password hashes + Google-linked accounts).
  - `comments`, `likes`, `history` — per-anime social + resume-watch.
  - `watchlist` ("My List"), `lists` (public *tops* / private *collections*),
    `list_ratings` — user lists + 1–5 ratings on public lists.
  - `selfhost_cache` — self-host coverage marks (per anilistId → cached sub/dub
    eps, `ep_titles`, `total_eps`); written by the build-farm `cache-state` callback.
- **Elasticsearch 8.13 `anime` index** (container `elasticsearch`,
  in-net `elasticsearch:9200`): the search/suggest layer. Carries a
  `search_as_you_type` suggest field; facets for genres / tags / source /
  season; multilingual title search across en + romaji + native. Built
  and kept in sync by the ingest job, alongside the Mongo upserts.

AniChan uses its **own** db (`anime_db`) and **own** index (`anime`) on
infrastructure shared with a separate goongle project. AniChan never
touches goongle's `rfp_db` or other ES indices. See
[safety.md](safety.md).

## Catalog source — AniList

AniList GraphQL is the only upstream. The **only** AniList caller is the
ingest script (paced ~2.2 s/req; AniList caps offset pagination at 5000
entries + degrades to ~30 req/min). The backend request path is pure
Mongo/ES reads, with the single cached `/api/catalog/trending` exception
above. MAL/Jikan + TMDB are possible **future** enrichment sources, not
wired today.

## Data pipeline — `scripts/ingest.py`

A standalone CLI in the backend repo, not imported by the running app.
Run it on the server:

```bash
docker exec anime-backend python -m scripts.ingest <mode>
```

Modes:

| Mode             | What it does                                                                              |
|------------------|------------------------------------------------------------------------------------------|
| `full`           | popularity sweep + per-`startDate`-year slices (full catalog build)                       |
| `years [from] [to]` | ingest entries by start-date year range                                                |
| `popular [pages]`| popularity-ordered sweep, N pages                                                         |
| `enrich [limit]` | per-anime heavy fields (relations/characters/staff/recommendations/reviews). **Idempotent catch-up** — only touches docs missing the `characters` field |
| `sample [n]`     | quick N-entry pull for smoke testing                                                      |

`enrich` is the catch-up path: rerunning it only fills in docs that
haven't been enriched yet, so it's safe to re-run after a `full`/`years`
sweep adds new lightweight entries.

See [infrastructure.md](infrastructure.md) for addresses/ports and
[deploy-loop.md](deploy-loop.md) for the build-on-server flow.
