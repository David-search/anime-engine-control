# CI/CD templates

The GitHub Actions workflow files committed to AniChan's two service repos.
Both run on GitHub's hosted `ubuntu-latest` runners (there is **no
self-hosted runner** for AniChan) and deploy to the single host
`vast-canada-2` (`70.30.158.46`, SSH port `43730`).

## The flow

On **push to `main`** (or manual `workflow_dispatch`), each workflow:

1. **Builds** the service Docker image on the hosted runner.
2. **Saves + compresses** it: `docker save <image>:latest | gzip > <svc>.tar.gz`.
3. **SCPs** the tarball to `/home/anime/<svc>/` on `vast-canada-2`.
4. **SSHes** in and runs `docker load -i <svc>.tar.gz` then
   `docker compose up -d --no-build` (loads the just-built image rather than
   rebuilding on the server), cleans up the tarball, and prunes dangling
   images.

There is a single `main` branch per repo — no `dev` branch, no
per-environment fan-out.

## Required GitHub secrets

These live in each repo's **Settings → Secrets and variables → Actions**.
Claude **cannot** set them — only the repo owner (`David-search`) can.

| Secret | Repos | Value |
| --- | --- | --- |
| `SERVER_SSH_KEY` | both | private key for `root@70.30.158.46:43730` (vast-canada-2) |
| `NEXT_PUBLIC_BACKEND_URL` | frontend only | `https://anichan.net` (public HTTPS origin via the edge; baked as a build arg) |

## Without the secrets, the workflow fails

The SCP/SSH steps have no fallback — if `SERVER_SSH_KEY` is missing the copy
and deploy steps error out, and a missing `NEXT_PUBLIC_BACKEND_URL` bakes an
empty backend URL into the frontend bundle. **Until the owner adds these
secrets, the CI/CD path is non-functional**, so the working deploy is
**build-on-server**:

```bash
# sync source to /home/anime/<svc>/ over vast-canada-2, then:
ssh vast-canada-2 'cd /home/anime/<svc> && docker compose up -d --build'
```

(`docker compose` reads `/home/anime/<svc>/.env`, the runtime source of
truth, and the compose files carry `build: .`.) Verify the public health URL
afterwards — backend `http://70.30.158.46:43577`, frontend
`http://70.30.158.46:43879`.

## Files

- [`backend.yml`](backend.yml) — committed at
  `.github/workflows/ci-cd.yml` in `anime-engine-backend`. Builds image
  `anime-engine-backend`, deploys to `/home/anime/backend`.
- [`frontend.yml`](frontend.yml) — committed at
  `.github/workflows/ci-cd.yml` in `anime-engine-frontend`. Builds image
  `anime-engine-frontend` with the `NEXT_PUBLIC_BACKEND_URL` build arg,
  deploys to `/home/anime/frontend`.

Both target `vast-canada-2` directly; there is no separate frontend host —
unlike goongle, AniChan is a single host.
