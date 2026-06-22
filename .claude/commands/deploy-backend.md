---
description: Build + deploy the backend on vast-canada-2 (build-on-server), verify /health
argument-hint: <commit message> (optional — only used if you also want to push to main)
---

Assumes you've used [`/work-on backend`](work-on.md) and made edits in
`work/backend/`. **AniChan deploys by building on the server** — there is
no self-hosted runner and no `dev` branch. The flow: sync the local
source up to `/home/anime/backend/`, then `docker compose up -d --build`
(compose has `build: .` and reads `/home/anime/backend/.env`), then
verify the public `/health`.

```bash
set -a && source .env && set +a

# 1) Sync source → /home/anime/backend/  (preserve the on-server .env, which
#    is the runtime source of truth and is NOT in the repo).
rsync -az --delete \
  --exclude '.git' --exclude '.env' --exclude '__pycache__' \
  -e "ssh -p $SSH_PORT" \
  work/backend/ "$SSH_USER@$SSH_HOST:/home/anime/backend/"

# (no rsync? scp the tree instead:)
#   scp -q -P "$SSH_PORT" -r work/backend/* "$SSH_USER@$SSH_HOST:/home/anime/backend/"

# 2) Rebuild + restart on the server.
ssh -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" \
  'cd /home/anime/backend && docker compose up -d --build'

# 3) Verify (anime-backend: host 8008 → container 8000 → public 43577).
echo "waiting for backend to come up..."
for i in $(seq 1 30); do
  if curl -fsS "$BACKEND_URL/health" >/dev/null 2>&1; then break; fi
  sleep 2
done
curl -fsS "$BACKEND_URL/health" && echo "  → $BACKEND_URL/health OK" \
  || { echo "health check FAILED at $BACKEND_URL/health"; \
       ssh -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" 'docker logs --tail 50 anime-backend'; }
```

Health URL: <http://70.30.158.46:43577/health>. Container `anime-backend`
on `goongle-network`; tail with
`ssh -p $SSH_PORT $SSH_USER@$SSH_HOST 'docker logs -f anime-backend'`.

After it lands, run [`/test-search`](test-search.md) to confirm the
catalog/search contract is still green.

## CI/CD alternative (currently failing)

The repo also has `.github/workflows/ci-cd.yml`: **push to `main`** →
GitHub Actions builds the image → `docker save | gzip` → scp → server
`docker load` + `docker compose up`. To use it instead of build-on-server:

```bash
cd work/backend && git add -A \
  && git -c user.name="$GIT_AUTHOR_NAME" -c user.email="$GIT_AUTHOR_EMAIL" \
       commit -m "${ARGUMENTS:-deploy backend}" \
  && git push origin main
```

It **fails until the repo owner adds the GitHub Actions secret
`SERVER_SSH_KEY`** (private key for `root@70.30.158.46:43730`). Claude
cannot set GitHub secrets — only the owner can, in repo Settings →
Secrets. Until then, use the build-on-server flow above.
