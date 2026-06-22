#!/usr/bin/env bash
# Helper: fetch the on-server .env for a service into work/<service>/.env.
# Source of truth is /home/anime/<service>/.env on the AniChan server.
# Uses local cp when the file exists on this filesystem (we're running on
# the server itself), scp otherwise. Idempotent — overwrites destination.

set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: fetch-env.sh <service>  (frontend | backend)" >&2
  exit 1
fi

SVC="$1"
LOCAL_SRC="/home/anime/$SVC/.env"
DEST="work/$SVC/.env"

cd "$(dirname "$0")/../.."

if [ ! -d "work/$SVC" ]; then
  echo "[fetch-env] work/$SVC does not exist — run /work-on $SVC or /setup-all first" >&2
  exit 1
fi

if [ -f "$LOCAL_SRC" ]; then
  cp "$LOCAL_SRC" "$DEST"
  echo "[fetch-env] $SVC: copied from $LOCAL_SRC"
else
  : "${SSH_HOST:?SSH_HOST not set — source .env first}"
  : "${SSH_PORT:?SSH_PORT not set}"
  : "${SSH_USER:?SSH_USER not set}"
  : "${SSH_KEY:?SSH_KEY not set}"
  scp -q -P "$SSH_PORT" -i "$SSH_KEY" \
    "$SSH_USER@$SSH_HOST:$LOCAL_SRC" "$DEST"
  echo "[fetch-env] $SVC: scp'd from $SSH_HOST:$LOCAL_SRC"
fi

chmod 600 "$DEST"
