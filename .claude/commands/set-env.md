---
description: Update KEY=VALUE in a service's on-server .env, re-sync the local mirror — does NOT restart the container
argument-hint: <service> KEY=VALUE [KEY=VALUE ...]   (service: backend | frontend)
---

Updates the canonical `/home/anime/<service>/.env` on the AniChan server
(`vast-canada-2`), then re-pulls it into `work/<service>/.env`. **Does
not restart the container.** AniChan deploys by building on the server,
and `env_file` is read at container creation — so the next
`docker compose up -d --build` (your normal deploy) picks the new value
up automatically. Restarting earlier is usually unnecessary churn.

```bash
set -a && source .env && set +a

read -r SVC FIRST REST <<< "$ARGUMENTS"
PAIRS="$FIRST $REST"

case "$SVC" in
  backend|frontend) ;;
  "") echo "usage: /set-env <service> KEY=VALUE [KEY=VALUE ...]"; exit 1 ;;
  *) echo "unknown service: $SVC (one of: backend, frontend)"; exit 1 ;;
esac

if [ -z "$FIRST" ]; then
  echo "no KEY=VALUE pairs provided"
  exit 1
fi

ENV_PATH="/home/anime/$SVC/.env"

# If the canonical file is on this filesystem (running on the server),
# write directly. Otherwise stream the helper to the server over SSH.
if [ -f "$ENV_PATH" ]; then
  python3 .claude/scripts/set-env.py "$ENV_PATH" $PAIRS
else
  : "${SSH_HOST:?}"; : "${SSH_PORT:?}"; : "${SSH_USER:?}"
  ssh -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" \
    "python3 - $ENV_PATH $PAIRS" < .claude/scripts/set-env.py
fi

# Re-sync the local mirror so work/<svc>/.env reflects the new state
bash .claude/scripts/fetch-env.sh "$SVC"

echo
echo "✓ updated $ENV_PATH"
echo "  local mirror: work/$SVC/.env"
echo
echo "The anime-$SVC container is still running with the OLD value."
echo "You almost certainly do NOT want to restart now — the next"
echo "build-on-server deploy reads /home/anime/$SVC/.env at container"
echo "creation, so a rebuild is enough."
echo
echo "If you DO need the new value live before the next deploy, rebuild"
echo "deliberately on the server:"
echo "  cd /home/anime/$SVC && docker compose up -d --build"
```

After this command runs, **do not** restart the container unless the
user asks. The normal flow is:

1. `/set-env backend ELASTIC_INDEX=anime_v2`
2. (eventual) edit code that consumes the new value
3. Deploy — sync source to `/home/anime/backend` and
   `docker compose up -d --build`, which reads the new `.env` for free.

Don't insert a manual rebuild between steps 1 and 3 unless the value is
needed for a probe/test before the next push.

> **Secrets:** never write the real Mongo/ES passwords into a committed
> file — the canonical values already live in `/home/anime/<svc>/.env`
> on the server. In docs use the placeholder
> `<stored in control .env on the server>`.

Relies on [`.claude/scripts/set-env.py`](../scripts/set-env.py) (in-place
KEY=VALUE editor) and [`.claude/scripts/fetch-env.sh`](../scripts/fetch-env.sh)
(re-pull the mirror).
