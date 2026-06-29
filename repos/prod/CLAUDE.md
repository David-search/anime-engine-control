# Prod boundary

The live AniChan containers serve real users. From this repo they are
**read-mostly**: probe them, tail their logs, verify their public URLs.
The **only** way to change what's running is a deliberate deploy
(build-on-server or CI/CD) — never hand-edit files on the server, never
`docker restart` to "pick up" an edit (the code is `COPY`'d at build
time, so a restart changes nothing), and never reconfigure the shared
data stores.

There is **no `dev` branch** and **no self-hosted runner** here — that's
goongle's model, not ours. Each service has a single `main` branch that
deploys straight to its one container.

## What's in prod

Three hosts: the **web-goongle** nginx TLS edge (public `https://anichan.net`,
shared with goongle.net), the **vast-canada-2** app host (`70.30.158.46`, ssh
`-p 43730 root@…`; all containers on the external Docker network
`goongle-network`), and the **offshore** HLS origin (`185.255.120.59`).

| Container        | Branch deployed | Repo                                  | Host port       | Public (via edge) / origin            |
|------------------|-----------------|---------------------------------------|-----------------|---------------------------------------|
| `anime-frontend` | `main`          | `David-search/anime-engine-frontend`  | `8003 → 3000`   | **`https://anichan.net`** (live); origin `:43879` |
| `anime-backend`  | `main`          | `David-search/anime-engine-backend`   | `8008 → 8000`   | `https://anichan.net/api/*`; origin `:43577` |

The data stores below are **not** deployed by this repo — they're
long-lived, host-level containers **shared with a separate goongle
project**. AniChan uses its own Mongo db (`anime_db`) and ES index
(`anime`); it never touches goongle's.

| Container        | In-network            | Host port       | External                | Holds (AniChan)                       |
|------------------|-----------------------|-----------------|-------------------------|---------------------------------------|
| `mongodb`        | `mongodb:27017`       | `8002 → 27017`  | `70.30.158.46:43829`    | db `anime_db` (9): `anime`, `users`, `comments`, `likes`, `history`, `watchlist`, `lists`, `list_ratings`, `selfhost_cache` |
| `elasticsearch`  | `elasticsearch:9200`  | `8005 → 9200`   | `70.30.158.46:43505`    | index `anime` (suggest + facets + multilingual titles) |

## Allowed operations from this repo

- `/probe-es '/anime/_count'` (and other read GETs) against the ES
  cluster — it's **shared with goongle**, so there's no separate prod ES.
  Scope queries to the `anime` index.
- `/probe-mongo` — read queries against `anime_db` (collections,
  `findOne`, counts). Same shared `mongodb` container as goongle; stay in
  `anime_db`.
- `/tail-logs frontend` / `/tail-logs backend` — read-only log tail over
  SSH.
- `curl` GETs against the public URLs to verify a route
  (`https://anichan.net`, origin `http://70.30.158.46:43577/health`).
- `/ingest <mode>` — runs `docker exec anime-backend python -m
  scripts.ingest <mode>`. Writes to `anime_db` + the `anime` index
  (AniChan's own), but a `full` run is long and AniList-rate-limited;
  treat it as a deliberate operation, not a casual probe.

## Disallowed from this repo

- **Hand-editing on-server files.** Never `ssh server vim
  /home/anime/<svc>/...`. All source changes flow through git +
  build-on-server. The on-server `/home/anime/<svc>/.env` is the only
  thing edited in place, and only via `/set-env`.
- **`docker restart` as a deploy.** Code is `COPY`'d at build time — a
  restart picks up nothing. Use `docker compose up -d --build`.
- **Touching the shared data stores.** Never restart, recreate, or
  reconfigure `mongodb` / `elasticsearch`, and never drop the `anime_db`
  database, a collection, or the `anime` index without explicit
  confirmation — they're co-tenant with goongle.
- **Force-pushes to `main`.** The `.claude/settings.json` deny-list
  blocks `git push --force` / `-f` from inside `work/`.

## Why it's gated

- Prod serves real users — a broken deploy is visible immediately on the
  public URL.
- The data stores are **shared with goongle**: a careless
  `mongodb`/`elasticsearch` restart or an index/collection drop hits
  **both** projects, not just AniChan. The blast radius is wider than it
  looks.
- The control repo's slash commands are convenience wrappers — they don't
  replace a deliberate decision to ship.

## Shipping to prod

Same `main` branch, same one container per service — "shipping" is just a
deploy. The primary, working path is **build-on-server**:

```bash
/deploy-frontend          # sync work/frontend → /home/anime/frontend, compose up --build, verify
/deploy-backend           # sync work/backend  → /home/anime/backend,  compose up --build, verify
```

Each syncs the local source up to `/home/anime/<svc>/`, runs
`docker compose up -d --build` (compose has `build: .` and reads the
on-server `.env`), then verifies the public health URL. After a backend
deploy that touches search, run `/test-search` to confirm the
catalog/search contract is still green.

### CI/CD alternative (currently failing)

Each repo also has `.github/workflows/ci-cd.yml`: **push to `main`** →
GitHub Actions builds the image → `docker save | gzip` → scp → server
`docker load` + `docker compose up`. It **fails** until the repo owner
adds the GitHub Actions secrets — `SERVER_SSH_KEY` (both repos) and
`NEXT_PUBLIC_BACKEND_URL=https://anichan.net` (frontend). Claude
**cannot** set GitHub secrets — only the owner can, in repo Settings →
Secrets. Until then, build-on-server is the only working path.
