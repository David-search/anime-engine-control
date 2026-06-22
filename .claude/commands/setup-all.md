---
description: Clone both service repos into work/ in parallel, on main branch
---

One-shot setup. Clones both service repos in parallel into
`work/<service>/`, each on its `main` branch. After this, Read/Edit/grep
all run at filesystem speed across the whole stack — much faster than
hitting the contents API per file.

Idempotent: if a clone already exists, it just `git fetch origin main &&
git checkout main && git pull` to bring it up to date.

```bash
set -a && source .env && set +a

mkdir -p work

clone_or_update() {
  local SERVICE="$1"
  local REPO_URL="$2"
  local DEST="work/$SERVICE"
  local AUTHED_URL
  AUTHED_URL="$(echo "$REPO_URL" | sed -E "s|https://|https://${GIT_AUTHOR_NAME:-x-access-token}:${GITHUB_TOKEN}@|")"

  if [ ! -d "$DEST/.git" ]; then
    git clone --quiet "$AUTHED_URL" "$DEST" 2>&1 | sed "s/^/[$SERVICE] /"
  fi
  (
    cd "$DEST"
    git fetch origin --quiet
    git checkout main --quiet 2>/dev/null || git checkout -b main origin/main --quiet
    git pull origin main --quiet
    echo "[$SERVICE] $(git rev-parse --short HEAD) on $(git branch --show-current)"
  )
  scp -q -P "$SSH_PORT" "$SSH_USER@$SSH_HOST:/home/anime/$SERVICE/.env" "$DEST/.env" \
    && chmod 600 "$DEST/.env" \
    && echo "[$SERVICE] .env synced from /home/anime/$SERVICE/.env"
}

# Run both in parallel
clone_or_update frontend "$REPO_FRONTEND" &
clone_or_update backend  "$REPO_BACKEND"  &
wait

echo
echo "ready. work/ now contains:"
ls -1d work/*/
```

> The SessionStart hook already auto-syncs the control repo + `work/{frontend,backend}`,
> so on a fresh session both clones are usually current — this command is
> the explicit/idempotent way to (re)establish them.

After this, edits go through the normal flow:

```
/work-on <service>          # ensures the one you're touching is current
                            # (already true post-/setup-all)
# edit work/<service>/...
/deploy-<service>           # build on vast-canada-2, verify the health URL
```
