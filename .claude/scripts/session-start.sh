#!/usr/bin/env bash
# SessionStart hook — emits a status banner about the state of
# anime-engine-control + work/. Output is JSON with hookSpecificOutput
# .additionalContext so Claude reads it as injected context.
# CLAUDE.md instructs Claude to greet the user with this state +
# the system diagram on the first turn.

set -euo pipefail

cd "$(dirname "$0")/../.."

# 1. Sync anime-engine-control itself with origin (fast-forward only)
control_status="(unknown)"
branch=$(git branch --show-current 2>/dev/null || echo "?")
if [ "$branch" != "main" ]; then
  control_status="on feature branch '$branch' — skipped sync"
elif ! git diff --quiet || ! git diff --cached --quiet; then
  control_status="uncommitted changes in anime-engine-control — skipped sync"
else
  if git fetch --quiet origin main 2>/dev/null; then
    behind=$(git rev-list --count HEAD..origin/main 2>/dev/null || echo 0)
    ahead=$(git rev-list --count origin/main..HEAD 2>/dev/null || echo 0)
    if [ "$behind" -gt 0 ] && [ "$ahead" -eq 0 ]; then
      pulled=$(git pull --ff-only --quiet origin main 2>&1 && echo "ok" || echo "fail")
      if [ "$pulled" = "ok" ]; then
        control_status="pulled $behind new commit(s) from origin/main"
      else
        control_status="behind by $behind but pull failed — check manually"
      fi
    elif [ "$ahead" -gt 0 ] && [ "$behind" -eq 0 ]; then
      control_status="ahead of origin/main by $ahead unpushed commit(s)"
    elif [ "$ahead" -gt 0 ] && [ "$behind" -gt 0 ]; then
      control_status="diverged from origin/main (ahead $ahead, behind $behind) — handle manually"
    else
      control_status="up to date with origin/main"
    fi
  else
    control_status="fetch failed (offline?) — skipped sync"
  fi
fi

services=(frontend backend)
missing=()
present_lines=()

# Source .env so REPO_*, GITHUB_TOKEN, GITHUB_USER are available to clone + fetch-env
env_loaded=0
if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
  env_loaded=1
fi

# Resolve a service short name to its REPO_<KEY> URL
repo_url_for() {
  case "$1" in
    frontend)  echo "${REPO_FRONTEND:-}" ;;
    backend)   echo "${REPO_BACKEND:-}" ;;
  esac
}

clone_missing() {
  # Clone work/<svc>, checkout main, then fetch-env.
  # Echoes a single status line.
  local svc="$1"
  local dest="work/$svc"
  local repo_url authed
  repo_url=$(repo_url_for "$svc")

  if [ -z "$repo_url" ] || [ -z "${GITHUB_TOKEN:-}" ]; then
    echo "  ✗ $svc — missing (REPO_* or GITHUB_TOKEN not set in .env; can't auto-clone)"
    return
  fi

  authed="$(echo "$repo_url" | sed -E "s|https://|https://${GITHUB_USER:-x-access-token}:${GITHUB_TOKEN}@|")"
  if ! git clone --quiet "$authed" "$dest" 2>/dev/null; then
    echo "  ✗ $svc — clone failed"
    return
  fi
  (
    cd "$dest"
    git fetch origin --quiet 2>/dev/null || true
    git checkout main --quiet
  )
  bash .claude/scripts/fetch-env.sh "$svc" >/dev/null 2>&1 || true
  local svc_branch svc_sha
  svc_branch=$(git -C "$dest" branch --show-current 2>/dev/null || echo "?")
  svc_sha=$(git -C "$dest" rev-parse --short HEAD 2>/dev/null || echo "?")
  echo "  + $svc — $svc_branch @ $svc_sha (cloned + .env synced)"
}

sync_clone() {
  # fast-forward-pull a work/<svc> if branch is main, clean tree,
  # not ahead. Echoes a single status line.
  local svc="$1"
  local dir="work/$svc"
  local svc_branch svc_sha note=""
  svc_branch=$(git -C "$dir" branch --show-current 2>/dev/null || echo "?")

  if [ "$svc_branch" != "main" ]; then
    note=" (on feature branch '$svc_branch' — skipped pull)"
  elif ! git -C "$dir" diff --quiet || ! git -C "$dir" diff --cached --quiet; then
    note=" (uncommitted changes — skipped pull)"
  else
    if git -C "$dir" fetch --quiet origin "$svc_branch" 2>/dev/null; then
      local b a
      b=$(git -C "$dir" rev-list --count "HEAD..origin/$svc_branch" 2>/dev/null || echo 0)
      a=$(git -C "$dir" rev-list --count "origin/$svc_branch..HEAD" 2>/dev/null || echo 0)
      if [ "$b" -gt 0 ] && [ "$a" -eq 0 ]; then
        if git -C "$dir" pull --ff-only --quiet origin "$svc_branch" 2>/dev/null; then
          note=" (pulled $b new commit(s))"
        else
          note=" (behind by $b but pull failed)"
        fi
      elif [ "$a" -gt 0 ] && [ "$b" -eq 0 ]; then
        note=" (ahead of origin/$svc_branch by $a unpushed)"
      elif [ "$a" -gt 0 ] && [ "$b" -gt 0 ]; then
        note=" (diverged: ahead $a / behind $b — handle manually)"
      fi
    else
      note=" (fetch failed — offline?)"
    fi
  fi
  svc_sha=$(git -C "$dir" rev-parse --short HEAD 2>/dev/null || echo "?")
  echo "  ✓ $svc — $svc_branch @ $svc_sha$note"
}

# For each service: sync if cloned, clone+sync if missing — all in parallel
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
for svc in "${services[@]}"; do
  dir="work/$svc"
  if [ -d "$dir/.git" ]; then
    sync_clone "$svc" > "$tmpdir/$svc" &
  else
    if [ "$env_loaded" = "1" ]; then
      clone_missing "$svc" > "$tmpdir/$svc" &
    else
      echo "  ? $svc — not cloned (and .env missing — can't auto-clone)" > "$tmpdir/$svc"
      missing+=("$svc")
    fi
  fi
done
wait
for svc in "${services[@]}"; do
  if [ -f "$tmpdir/$svc" ]; then
    present_lines+=("$(cat "$tmpdir/$svc")")
  fi
done

# Build the banner
banner="=== anime-engine-control session ==="$'\n'
banner+="anime-engine-control: $control_status"$'\n'
banner+=$'\n'
if [ ${#present_lines[@]} -gt 0 ]; then
  banner+="work/ services:"$'\n'
  for line in "${present_lines[@]}"; do banner+="$line"$'\n'; done
fi
if [ ${#missing[@]} -gt 0 ]; then
  banner+="Couldn't auto-clone: ${missing[*]} — populate .env first (REPO_*, GITHUB_TOKEN)."$'\n'
fi
banner+=$'\n'
banner+="On the first turn: greet the user, READ STATE.md (current snapshot + PENDING list), run /startup (live check: git + 6 build nodes + offshore + app health), render the AniChan system diagram from CLAUDE.md, then summarise work/ state + anything off."$'\n'

# Emit JSON for the hook protocol
python3 -c '
import json,sys
text = sys.stdin.read()
print(json.dumps({
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": text,
  }
}))
' <<< "$banner"
