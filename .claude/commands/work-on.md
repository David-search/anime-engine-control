---
description: Ensure a local clone of a service repo exists in work/, on the main branch
argument-hint: <service> — one of: frontend | backend
---

`/work-on $ARGUMENTS`

```bash
set -a && source .env && set +a
SERVICE="$ARGUMENTS"

case "$SERVICE" in
  frontend)  REPO_URL="$REPO_FRONTEND" ;;
  backend)   REPO_URL="$REPO_BACKEND" ;;
  *) echo "unknown service: $SERVICE (frontend | backend)"; exit 1 ;;
esac

mkdir -p work
DEST="work/$SERVICE"

# Inject token into the URL so non-interactive clone works.
AUTHED_URL="$(echo "$REPO_URL" | sed -E "s|https://|https://${GIT_AUTHOR_NAME:-x-access-token}:${GITHUB_TOKEN}@|")"

if [ ! -d "$DEST/.git" ]; then
  git clone "$AUTHED_URL" "$DEST"
fi

cd "$DEST"
git fetch origin --quiet
git checkout main --quiet 2>/dev/null || git checkout -b main origin/main --quiet
git pull origin main --quiet

cd ../..
# Sync the service's runtime .env from vast-canada-2 (source of truth)
scp -q -P "$SSH_PORT" "$SSH_USER@$SSH_HOST:/home/anime/$SERVICE/.env" "work/$SERVICE/.env"
chmod 600 "work/$SERVICE/.env"

echo
echo "ready: work/$SERVICE on $(git -C work/$SERVICE branch --show-current) @ $(git -C work/$SERVICE rev-parse --short HEAD)"
echo "  .env: synced from /home/anime/$SERVICE/.env"
```

After this you can use Read/Edit on `work/$SERVICE/...` like any local
checkout. The `.env` matches what runs on vast-canada-2, so
`docker compose up` from `work/$SERVICE/` works locally if you want to
debug against the same Mongo/ES (via the public ports).

> The on-server `/home/anime/$SERVICE/.env` is the runtime source of
> truth — editing the local mirror only affects your debug runs, not the
> deployed container.

When done, [`/deploy-frontend`](deploy-frontend.md) or
[`/deploy-backend`](deploy-backend.md) builds the service on the server.
