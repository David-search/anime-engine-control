# CI/CD operations

How the GitHub Actions workflows are wired, why they currently fail, and
the manual build-on-server fallback that is the **primary** deploy path
today.

**This DIFFERS from goongle.** There is **no self-hosted runner**, no
runner pool to register, no `dev` branch, and no in-place git-pull
deploy. AniChan's CI uses GitHub-hosted runners that build an image and
ship it to the one host over SSH. Until the required secrets are added,
CI does not run; deploys happen via build-on-server (see
[deploy-loop.md](deploy-loop.md)).

## Topology

| Repo                                  | Branch | Runner            | Deploy target dir       | Container        |
|---------------------------------------|--------|-------------------|-------------------------|------------------|
| `David-search/anime-engine-backend`   | main   | GitHub-hosted     | `/home/anime/backend/`  | `anime-backend`  |
| `David-search/anime-engine-frontend`  | main   | GitHub-hosted     | `/home/anime/frontend/` | `anime-frontend` |

Both deploy to the single host `vast-canada-2`
(`root@70.30.158.46:43730`). There is no separate frontend host.

## The workflow (`.github/workflows/ci-cd.yml`)

Each service repo has one. On **push to `main`**:

1. GitHub-hosted runner checks out the repo.
2. `docker build` the service image (frontend also passes
   `--build-arg NEXT_PUBLIC_BACKEND_URL=...` so the public backend URL is
   baked in).
3. `docker save | gzip` the image to a tarball.
4. `scp` the tarball to the server (`/home/anime/<svc>/`).
5. ssh into the server: `docker load` the image, then
   `docker compose up -d` to recreate the container.

| Workflow                          | On `main` push                                                                                  |
|-----------------------------------|------------------------------------------------------------------------------------------------|
| `anime-engine-backend/ci-cd.yml`  | build `anime-backend` image → save\|gzip → scp → load + `docker compose up -d` → health check   |
| `anime-engine-frontend/ci-cd.yml` | build `anime-frontend` (bakes `NEXT_PUBLIC_BACKEND_URL`) → save\|gzip → scp → load + up → check |

The compose files on the server have `build: .`, but the CI path ships a
pre-built image and runs `docker compose up -d` against the loaded image
rather than rebuilding from source on the host. (The manual fallback,
by contrast, syncs source and uses `--build`.)

## Why it currently FAILS

The workflows reference repo secrets that haven't been added yet:

| Secret                    | Needed by         | Value                                   |
|---------------------------|-------------------|-----------------------------------------|
| `SERVER_SSH_KEY`          | both repos        | the private key for `root@70.30.158.46:43730` |
| `NEXT_PUBLIC_BACKEND_URL` | frontend repo     | `https://anichan.net` (public HTTPS origin via the edge) |

Without `SERVER_SSH_KEY`, the scp/ssh steps can't authenticate and the
job fails. Without `NEXT_PUBLIC_BACKEND_URL`, the frontend build bakes a
wrong/empty backend URL.

**Claude CANNOT set GitHub secrets.** Only the repo owner can, in
**Settings → Secrets and variables → Actions** for each repo. Steps for
the owner:

1. In `anime-engine-backend` → add `SERVER_SSH_KEY`.
2. In `anime-engine-frontend` → add `SERVER_SSH_KEY` **and**
   `NEXT_PUBLIC_BACKEND_URL=https://anichan.net` (the public HTTPS origin
   via the web-goongle edge — an `http://IP:port` would be mixed-content-blocked).
3. Re-run the failed workflow (or push a commit to `main`).

Until then, deploy with the manual fallback below.

## Manual build-on-server fallback (primary path today)

This is what's actually used until CI secrets land. Full detail in
[deploy-loop.md](deploy-loop.md):

```bash
# sync source up (exclude .git and the on-server source-of-truth .env)
rsync -az -e 'ssh -p 43730' --exclude '.git' --exclude '.env' \
  work/<svc>/ root@70.30.158.46:/home/anime/<svc>/

# build + recreate in place (compose has build:. and reads the on-server .env)
ssh vast-canada-2 'cd /home/anime/<svc> && docker compose up -d --build'

# verify
curl -sS http://70.30.158.46:43577/api/catalog/trending          # backend
curl -sS -o /dev/null -w '%{http_code}\n' http://70.30.158.46:43879   # frontend
```

## Modifying a workflow

Editing `.github/workflows/*` in a service repo requires the `workflow`
PAT scope (in addition to `repo`). If the `GITHUB_TOKEN` in the control
`.env` is `repo`-only, GitHub rejects pushes that touch workflow files.

1. Ensure `GITHUB_TOKEN` has both `repo` and `workflow` scope.
2. `/work-on <service>` to clone the repo into `work/`.
3. Edit `work/<service>/.github/workflows/ci-cd.yml`.
4. Commit + push to `main`.

## Watching a run

```bash
set -a && source .env && set +a
REPO=anime-engine-backend
curl -sS -H "Authorization: token $GITHUB_TOKEN" \
  "https://api.github.com/repos/David-search/$REPO/actions/runs?branch=main&per_page=1" \
  | python3 -c "import json,sys; r=json.load(sys.stdin)['workflow_runs'][0]; print(r['status'], r['conclusion'])"
```

To cancel a queued / in-progress run:

```bash
curl -sS -X POST -H "Authorization: token $GITHUB_TOKEN" \
  "https://api.github.com/repos/David-search/$REPO/actions/runs/<run_id>/cancel"
```

## Env source of truth

CI bakes only the frontend's `NEXT_PUBLIC_BACKEND_URL` (from the repo
secret). Everything else the containers read at runtime comes from
`/home/anime/<svc>/.env` **on the server** — that's the source of truth,
not anything in the repo or the workflow. See [secrets.md](secrets.md).
