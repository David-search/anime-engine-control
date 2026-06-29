---
description: Build + deploy the frontend on vast-canada-2 (build-on-server), verify the site
argument-hint: <commit message> (optional — only used if you also want to push to main)
---

Assumes you've used [`/work-on frontend`](work-on.md) and made edits in
`work/frontend/`. **AniChan deploys by building on the server** — there is
no self-hosted runner and no `dev` branch. The flow: sync the local
source up to `/home/anime/frontend/`, then `docker compose up -d --build`
(compose has `build: .` and reads `/home/anime/frontend/.env`), then
verify the public site.

> The frontend is Next.js 15 with **standalone output**, so
> `NEXT_PUBLIC_BACKEND_URL` is baked in at **build time**. The on-server
> `docker-compose.yml` passes it as a build arg —
> `NEXT_PUBLIC_BACKEND_URL=https://anichan.net` — sourced from
> `/home/anime/frontend/.env`. It must be the **public https origin**
> (the browser fetches `${NEXT_PUBLIC_BACKEND_URL}/api/...`, and nginx on
> `anichan.net` routes `/api` → backend). A bare `http://IP:port` here
> would be **blocked as mixed content** on the https site. If the deployed
> UI can't reach the API, check that arg first.

> ⚠️ **NEVER sync local env files over the server.** The on-server
> `/home/anime/frontend/{.env,.env.local}` are the **runtime source of
> truth** (they hold the real `FRONTEND_HOST_PORT=8003`, the
> `https://anichan.net` backend URL, the Google client id, and the
> Amplitude key — none of which are in the repo). The rsync below
> **must** exclude `.env` *and* `.env.local`. Overwriting them with a
> dev-local copy silently breaks the port mapping (→ 502 at the domain)
> and bakes a wrong backend URL on the next build. If you ever `scp` or
> `rsync` by hand, carry the same excludes. See
> [secrets.md](../guides/secrets.md).

```bash
set -a && source .env && set +a

# 1) Sync source → /home/anime/frontend/  (preserve the on-server env files —
#    .env AND .env.local are the source of truth — and skip build artifacts).
rsync -az --delete \
  --exclude '.git' --exclude '.env' --exclude '.env.local' \
  --exclude 'node_modules' --exclude '.next' --exclude 'public/jassub' \
  -e "ssh -p $SSH_PORT" \
  work/frontend/ "$SSH_USER@$SSH_HOST:/home/anime/frontend/"

# (no rsync? scp the tree instead — but scp can't exclude, so NEVER scp the
#  whole tree; scp only the specific files you changed, never .env/.env.local:)
#   scp -q -P "$SSH_PORT" work/frontend/components/Foo.tsx \
#       "$SSH_USER@$SSH_HOST:/home/anime/frontend/components/Foo.tsx"

# 2) Rebuild + restart on the server. compose passes NEXT_PUBLIC_BACKEND_URL
#    as a build arg from /home/anime/frontend/.env.
ssh -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" \
  'cd /home/anime/frontend && docker compose up -d --build'

# 3) Verify (anime-frontend: host 8003 → container 3000 → public 43879).
echo "waiting for frontend to come up..."
for i in $(seq 1 30); do
  if curl -fsS -o /dev/null "$FRONTEND_URL"; then break; fi
  sleep 2
done
curl -fsS -o /dev/null -w "%{http_code}" "$FRONTEND_URL" | grep -q '^200$' \
  && echo "  → $FRONTEND_URL OK" \
  || { echo "site check FAILED at $FRONTEND_URL"; \
       ssh -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" 'docker logs --tail 50 anime-frontend'; }
```

Site URL: <http://70.30.158.46:43879>. Container `anime-frontend` on
`goongle-network`; tail with
`ssh -p $SSH_PORT $SSH_USER@$SSH_HOST 'docker logs -f anime-frontend'`.

## CI/CD alternative (currently failing)

The repo also has `.github/workflows/ci-cd.yml`: **push to `main`** →
GitHub Actions builds the image → `docker save | gzip` → scp → server
`docker load` + `docker compose up`. To use it instead of build-on-server:

```bash
cd work/frontend && git add -A \
  && git -c user.name="$GIT_AUTHOR_NAME" -c user.email="$GIT_AUTHOR_EMAIL" \
       commit -m "${ARGUMENTS:-deploy frontend}" \
  && git push origin main
```

It **fails until the repo owner adds the GitHub Actions secrets
`SERVER_SSH_KEY`** (private key for `root@70.30.158.46:43730`) **and
`NEXT_PUBLIC_BACKEND_URL`** (= `https://anichan.net`, needed as the
build arg). Claude cannot set GitHub secrets — only the owner can, in repo
Settings → Secrets. Until then, use the build-on-server flow above.
