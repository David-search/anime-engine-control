# frontend — AniChan UI

Next.js 15 (App Router, `output: 'standalone'`). Container
`anime-frontend`, host port `8003 → container 3000`; **public at
https://anichan.net** via the web-goongle nginx edge (origin
`http://70.30.158.46:43879`). Every page reads from the backend; the
browser hits it at the URL baked in at build time
(`NEXT_PUBLIC_BACKEND_URL=https://anichan.net`, same-origin `/api/*`
through the edge), while SSR inside the container reaches it in-network
as `http://anime-backend:8000`.

| | URL |
|---|---|
| Public site | **`https://anichan.net`** (live; via the web-goongle edge) |
| Frontend origin (on server) | `http://localhost:8003` → public `http://70.30.158.46:43879` (behind edge) |
| Backend (browser, baked at build) | `https://anichan.net` (same-origin `/api/*` via the edge) |
| Backend (SSR, in-network) | `http://anime-backend:8000` |

## Routing

`app/` is the App Router root.

| Route             | File                                                | What it is                                                        |
|-------------------|-----------------------------------------------------|-------------------------------------------------------------------|
| `/`               | [app/page.tsx](app/page.tsx)                         | Home — trending + airing + popular rails                        |
| `/search`         | [app/search/page.tsx](app/search/page.tsx)          | Search results + filter UI (genres / tags / source / season facets)|
| `/anime/[id]`     | [app/anime/[id]/page.tsx](app/anime/[id]/page.tsx)  | Detail — synopsis, relations, characters, recommendations, episode list |
| `/watch/[id]/[ep]`          | [app/watch/[id]/[ep]/page.tsx](app/watch/[id]/[ep]/page.tsx)            | Player page (episode stream + episode switcher)                   |

`[id]` in the detail route is the AniList id — the same id the backend
catalog uses.

## API surface

[lib/api.ts](lib/api.ts) is the only module that talks to the backend,
typed against [lib/types.ts](lib/types.ts). It reads
`NEXT_PUBLIC_BACKEND_URL` for browser calls and the in-network base for
SSR.

| Function                       | Hits                          | Used by                          |
|--------------------------------|-------------------------------|----------------------------------|
| `getTrending()` / `getPopular()` / `getAiring()` | `GET /api/catalog/{trending,popular,airing}` | Home rails        |
| `getAnime(id)`                 | `GET /api/catalog/anime/{id}` | `/anime/[id]` detail             |
| `searchAnime(q)` / `browse(params)` / `browseServer/Client` | `GET /api/catalog/{search,browse}` | `/search` results + filter UI |
| `getFacets()` / `getGenres()`  | `GET /api/catalog/genres`     | filter dropdowns (genres/tags/years/formats) |
| `useAuth().login/register/googleLogin` ([lib/auth.tsx](lib/auth.tsx)) | `POST /api/auth/{login,register,google}` | Auth flows |

Social endpoints exist on the backend as **flat `/api/*` routes**
(`/api/comments`, `/api/likes`, `/api/history`, `/api/watchlist`,
`/api/lists/*` — **not** `/api/social`). The frontend may not wire all of
them yet — `Comments` is currently seeded from AniList reviews + local state.

## Components

Reusable UI lives in `components/`. Reuse before adding — check what's
there first.

| Component                                          | What it does                                                  |
|----------------------------------------------------|--------------------------------------------------------------|
| [components/AnimeCard.tsx](components/AnimeCard.tsx) | Single catalog card (poster, title, badges) — rails + search grid |
| [components/Row.tsx](components/Row.tsx)            | Horizontal scroller of `AnimeCard`s (home rails)             |
| [components/Header.tsx](components/Header.tsx)      | Top nav + search box + genres dropdown + auth entry point    |
| [components/FilterBar.tsx](components/FilterBar.tsx)| Faceted filter bar on `/search` (genres / tags / format / year / season) |
| [components/HostEmbed.tsx](components/HostEmbed.tsx)| iframe player for embed-type sources (e.g. anikoto/allmanga) on the watch panel |
| [components/AuthModal.tsx](components/AuthModal.tsx)| Email + Google (GIS) sign-in modal                          |
| [components/Comments.tsx](components/Comments.tsx)  | Comments thread (seeded with AniList reviews)               |
| [components/Reactions.tsx](components/Reactions.tsx)| Like / share buttons                                         |

## Auth

Two methods: **email** (signup/login → backend issues a JWT) and
**Google** (Google Identity Services / GIS button → backend verifies the
id token → JWT). The Google client id comes from `NEXT_PUBLIC_GOOGLE_CLIENT_ID`
(matching the backend's `GOOGLE_CLIENT_ID`). The JWT is what the social
`/api/*` calls carry for comments / likes / history.

## Env

| Var                              | Purpose                                                          |
|----------------------------------|-----------------------------------------------------------------|
| `NEXT_PUBLIC_BACKEND_URL`        | Backend base for browser calls — **baked at build time**, `https://anichan.net` (same-origin `/api/*` via the edge) |
| `NEXT_PUBLIC_GOOGLE_CLIENT_ID`   | Google GIS client id for sign-in                                |

Because `NEXT_PUBLIC_*` is inlined at build time, changing
`NEXT_PUBLIC_BACKEND_URL` requires a **rebuild**, not just a restart.

## Run locally

The synced `work/frontend/.env` mirrors the server. To run against the
public backend, set `NEXT_PUBLIC_BACKEND_URL=https://anichan.net` (or the
origin `http://70.30.158.46:43577` for a direct hit), then:

```bash
npm install
npm run dev            # Next.js on :3000
curl -sS http://localhost:3000/
```

Don't `docker compose up` from a laptop — the in-network SSR base
(`http://anime-backend:8000`) only resolves on `goongle-network`.

## Deploy — build on server

There is **no self-hosted runner and no `dev` branch**. Primary path is
build-on-server: sync `work/frontend/` up to `/home/anime/frontend/`,
then rebuild from the on-server compose (`build: .`, reads
`/home/anime/frontend/.env`):

```bash
ssh vast-canada-2 'cd /home/anime/frontend && docker compose up -d --build'
curl -fsS http://70.30.158.46:43879/
```

`/deploy-frontend` drives this end-to-end. The build needs
`NEXT_PUBLIC_BACKEND_URL=https://anichan.net` passed as a build
arg (the on-server compose wires it from `/home/anime/frontend/.env`) —
a wrong value here ships a frontend that points the browser at the wrong
backend. There's a CI/CD alt (`.github/workflows/ci-cd.yml`) but it
**fails** until the repo owner adds the Actions secrets `SERVER_SSH_KEY`
**and** `NEXT_PUBLIC_BACKEND_URL`. Use build-on-server until then.

Source is `COPY`'d into the image at build time; there's no bind mount.
`docker restart anime-frontend` does NOT pick up edits — always rebuild.

## Conventions

- **Client components carry `"use client"` at the top.** Pages default to
  server components (SSR-friendly) — use that for the catalog/detail
  reads, opt into client only where you need interactivity.
- **Code references in chat use markdown links** — `[file.tsx:42](app/file.tsx#L42)` —
  not backticks.
- **The backend response shape is the source of truth.** Adding a field
  to a card means changing the backend shaping first (see
  [../backend/CLAUDE.md](../backend/CLAUDE.md)), then reading it here.
- **Reuse existing components and `lib/api.ts`** before adding new ones.

## Common gotchas

- **`NEXT_PUBLIC_BACKEND_URL` is baked at build time.** A restart won't
  change it — only a rebuild. If the browser is hitting the wrong backend
  after a config change, you forgot to rebuild (or passed the wrong build
  arg). `/deploy-frontend` rebuilds.
- **Two backend bases, one for browser and one for SSR.** Browser uses
  the public `NEXT_PUBLIC_BACKEND_URL`; SSR inside the container uses
  in-network `http://anime-backend:8000`. Don't collapse them — a laptop
  can't resolve the in-network name, and the browser can't resolve it
  either.
- **`/anime/[id]` and the backend catalog id are both the AniList id.**
  Don't translate ids between the two.
- **Standalone output.** `output: 'standalone'` is what the Dockerfile
  relies on for the slim runtime image — don't remove it.
