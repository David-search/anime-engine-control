# Deploy loop — edit → build-on-server → verify

The control repo holds no source. Edits flow through git into the two
service repos. **This DIFFERS from goongle:** there is **no self-hosted
runner** and **no `dev` branch**. The working deploy is *build on the
server*.

## Standard flow (primary — build on server)

```
edit → sync source to /home/anime/<svc>/ → ssh: docker compose up -d --build → verify
```

Step by step:

```bash
# 1. Acquire the source locally (if not already in work/<svc>)
/work-on backend          # clones the repo into work/backend/, syncs its .env

# 2. Edit (use Read/Edit on work/backend/...)

# 3. Sync the service source to the on-server deploy dir
rsync -az -e 'ssh -p 43730' --exclude '.git' --exclude '.env' \
  work/backend/ root@70.30.158.46:/home/anime/backend/
#   (scp -P 43730 -r also works; --exclude .env so you don't clobber
#    the on-server source-of-truth .env)

# 4. Build + restart on the server (compose has build:. and reads
#    /home/anime/backend/.env)
ssh vast-canada-2 'cd /home/anime/backend && docker compose up -d --build'

# 5. Verify the public health URL
curl -sS http://70.30.158.46:43577/api/catalog/trending
```

`docker compose up -d --build` rebuilds the image in-place on the server
from the synced source, recreates the container, and reads
`/home/anime/<svc>/.env` for runtime config.

## Per-service mapping

| Service  | Repo                                  | Deploy dir              | Container        | Public URL                     |
|----------|---------------------------------------|-------------------------|------------------|--------------------------------|
| backend  | `David-search/anime-engine-backend`   | `/home/anime/backend/`  | `anime-backend`  | `http://70.30.158.46:43577`    |
| frontend | `David-search/anime-engine-frontend`  | `/home/anime/frontend/` | `anime-frontend` | `http://70.30.158.46:43879`    |

Both services build and run in-place on the **same** host
(`vast-canada-2`). There is no separate frontend host, no SCP-the-image
step in the primary flow. The frontend's `NEXT_PUBLIC_BACKEND_URL` is
baked at build time from `/home/anime/frontend/.env`, so a frontend
rebuild is required whenever the backend's public URL changes.

## Branch policy

- **Single `main` branch per repo.** No `dev`. All edits land on `main`.
- There is no prod/dev container split — `main` is the only line, and
  the build-on-server step is what makes a change live.
- Because there's no runner watching pushes, **pushing to `main` does
  not deploy by itself** (until the CI secrets are added — see below).
  The deploy is the explicit build-on-server step above.

## CI/CD alternate path (once secrets are added)

Each repo has `.github/workflows/ci-cd.yml`: push `main` → GitHub
Actions builds the image → `docker save | gzip` → `scp` to the server →
ssh `docker load` + `docker compose up -d`. It currently **FAILS** until
the repo owner adds the GitHub Actions secrets:

- `SERVER_SSH_KEY` (both repos)
- `NEXT_PUBLIC_BACKEND_URL=https://anichan.net` (frontend — public HTTPS origin via the edge)

Claude **cannot** set GitHub secrets — only the owner can, in repo
**Settings → Secrets and variables → Actions**. Until then, use the
build-on-server flow above. Full detail in [ci-cd.md](ci-cd.md).

## Env source of truth

`/home/anime/<svc>/.env` **on the server** is the source of truth for
runtime config — not the local `work/<svc>/.env` mirror. `/work-on` and
`/setup-all` `scp` the on-server file down into `work/<svc>/.env` at
clone time so local tooling sees the right values, but edits to the
local mirror get clobbered on the next sync. To change a runtime value,
edit it on the server, then re-sync. Always exclude `.env` from the
source rsync (step 3) so you don't overwrite it. See [secrets.md](secrets.md).

## Verifying after a deploy

```bash
# Backend responds (catalog read path is pure Mongo/ES)
curl -sS http://70.30.158.46:43577/api/catalog/trending
curl -sS "http://70.30.158.46:43577/api/search?q=frieren"

# Frontend up
curl -sS -o /dev/null -w '%{http_code}\n' http://70.30.158.46:43879

# Boot logs
ssh vast-canada-2 'docker logs --tail 50 anime-backend'
ssh vast-canada-2 'docker logs --tail 50 anime-frontend'

# Data layers reachable from inside the backend container
ssh vast-canada-2 'docker exec anime-backend python -c "print(\"ok\")"'
```

## Running the ingest pipeline

The catalog build/refresh is a separate, manual step — it does not run
on deploy. Execute it inside the running backend container:

```bash
ssh vast-canada-2 'docker exec anime-backend python -m scripts.ingest sample 50'   # smoke
ssh vast-canada-2 'docker exec anime-backend python -m scripts.ingest enrich 500'  # catch-up
```

See the pipeline section in [architecture.md](architecture.md#data-pipeline--scriptsingestpy)
for all modes.

## Rollback

If a deploy breaks something, revert the source and rebuild:

```bash
cd work/<service>
git revert HEAD               # undo the last commit
git push origin main
# then re-run the build-on-server flow (sync + docker compose up -d --build)
rsync -az -e 'ssh -p 43730' --exclude '.git' --exclude '.env' \
  work/<service>/ root@70.30.158.46:/home/anime/<service>/
ssh vast-canada-2 'cd /home/anime/<service> && docker compose up -d --build'
```

Docker keeps the previous image until the new one builds successfully,
so a failed build leaves the running container untouched. If a build
fails mid-way, the old container keeps serving — fix and re-run.

## When CI fails

See [ci-cd.md](ci-cd.md) for the workflow shape, the missing-secrets
failure mode, and the manual build-on-server fallback (which is the
primary path today).
