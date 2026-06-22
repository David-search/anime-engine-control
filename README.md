# anime-engine-control

Claude orchestration plane for the **AniChan** stack (planned domain
`anichan.net`). Clone this anywhere, fill in `.env`, and Claude has
everything it needs to inspect, edit, test, and deploy the stack.

The repo is **docs + Claude config + slash commands**. There is no
production code here. Source code lives in the two service repos:

| Service  | Repo                                  | Branches | Deploy                          |
|----------|---------------------------------------|----------|---------------------------------|
| frontend | `David-search/anime-engine-frontend`  | `main`   | build-on-server (CI/CD alt)     |
| backend  | `David-search/anime-engine-backend`   | `main`   | build-on-server (CI/CD alt)     |

A single `main` branch per repo — **no `dev` branch and no self-hosted
runner** (this differs from goongle). The primary deploy is
build-on-server: sync source to `/home/anime/<svc>/` and
`docker compose up -d --build`. A CI/CD alt path exists but currently
fails until the owner adds GitHub secrets. See
[.claude/guides/deploy-loop.md](.claude/guides/deploy-loop.md).

## Setup

```bash
git clone https://github.com/David-search/anime-engine-control.git
cd anime-engine-control
cp .env.example .env
$EDITOR .env       # fill in GitHub user, SSH host/key, Mongo/ES creds
```

Open Claude in this directory; `CLAUDE.md` auto-loads with the
infrastructure map and deploy semantics. Try:

```
/probe-es '/anime/_count'              # doc count in the ES "anime" index
/probe-mongo 'db.anime.countDocuments()'  # catalog size in Mongo anime_db
/ingest sample 50                      # smoke-ingest 50 from AniList → Mongo + ES
/test-search "frieren"                 # search regression probe over SSH
/setup-all                             # clone both repos in parallel, sync each .env
/work-on backend                       # clone one repo, sync its .env, ready to edit
/sync-envs                             # re-pull each on-server .env into work/<service>/
/set-env backend ELASTIC_INDEX=anime   # update the canonical on-server .env
/deploy-backend                        # sync source → compose up -d --build → verify
/deploy-frontend                       # same for the Next.js frontend
/ssh 'docker ps'                       # one-shot command on vast-canada-2
/tail-logs backend                     # stream anime-backend container logs
```

See [CLAUDE.md](CLAUDE.md) for the full overview, [.claude/commands/](.claude/commands/)
for every slash command, and [.claude/guides/](.claude/guides/) for the
deeper pieces (architecture, deploy loop, ingest, safety, secrets).

## Deploy

The primary path is **build-on-server**: `/deploy-<service>` syncs the
service source to `/home/anime/<svc>/` over `vast-canada-2`, then runs
`docker compose up -d --build` (compose has `build: .` and reads the
on-server `.env`), then verifies the public health URL.

```
/deploy-backend                  # anime-backend  → public :43577
/deploy-frontend                 # anime-frontend → public :43879
```

A CI/CD alt path lives in each repo's `.github/workflows/ci-cd.yml`
(push `main` → Actions builds image → `docker save | gzip` → scp →
`docker load` + `compose up`). It **currently fails** until the repo
owner adds GitHub Actions secrets — Claude **cannot** set these:

- both repos: `SERVER_SSH_KEY` (private key for `root@70.30.158.46:43730`)
- frontend repo: `NEXT_PUBLIC_BACKEND_URL` = `http://70.30.158.46:43577`

Server deploy dirs: `/home/anime/frontend`, `/home/anime/backend`
(each holds `Dockerfile`, `docker-compose.yml` with `build: .`, and a
`.env` that is the source of truth for runtime config). All containers
run on the external Docker network `goongle-network`, which already
exists.

## Env source of truth

The canonical runtime config for each service is
`/home/anime/<svc>/.env` **on the server**, not the local
`work/<svc>/.env` mirror and not these markdown files. `/work-on`,
`/setup-all`, and `/sync-envs` pull the server `.env` into the local
clone; `/set-env` writes back to the server. Never edit
`work/<svc>/.env` directly — it's clobbered on the next sync. And never
commit real Mongo/ES passwords: use the placeholder
`<stored in control .env on the server>` (the push auto-classifier
blocks commits containing the real password).
