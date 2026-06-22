# Secrets management

## Where they live

There are two distinct `.env` files. Don't confuse them.

1. **Control `.env`** — at the control repo root
   (`/Users/admin/Documents/anime/claude/.env`), gitignored. Holds the
   credentials the slash commands / tooling need to reach the server,
   GitHub, and the data layers off-server. Populated from `.env.example`:

   ```bash
   cp .env.example .env
   $EDITOR .env
   ```

   `.env` never gets committed.

2. **On-server per-service `.env`** — `/home/anime/<svc>/.env` on
   `vast-canada-2`. These are the files the **running containers**
   actually read at build/run time. **The on-server file is the source
   of truth** for runtime config.

## What's in the control `.env`

See `.env.example` for the full template. Categorised:

- **GitHub auth** (`GITHUB_TOKEN`, `GIT_AUTHOR_*`) — clone, commit, push
  to the two `anime-engine-*` service repos.
- **SSH** (`SSH_HOST`, `SSH_PORT`, `SSH_USER`, `SSH_KEY`) — every command
  that hits `vast-canada-2`: source sync, build-on-server, log tails,
  ingest runs.
- **Service URLs** — the external public addresses for off-server probes
  (`http://70.30.158.46:43577` backend, `http://70.30.158.46:43879`
  frontend).
- **Data-layer creds (off-server form)** — `ELASTIC_URL` /
  `ELASTIC_USER` / `ELASTIC_PASSWORD` and `MONGO_URI` pointing at the
  **external** ports (`43505` / `43829`) for probing from your machine.

## What's in the on-server per-service `.env`

These contain things the control `.env` doesn't — specifically the
**in-network** addresses and the real secrets:

- in-network addresses (`mongodb:27017`, `http://elasticsearch:9200`) —
  used by the backend to reach the data stores over `goongle-network`
- the real Mongo/ES credentials (in their split form for the backend:
  `MONGO_URI=...@mongodb:27017/anime_db?authSource=admin`,
  `ELASTIC_USER` / `ELASTIC_PASSWORD`, `ELASTIC_INDEX=anime`)
- per-service config (`NEXT_PUBLIC_BACKEND_URL` for the frontend — baked
  at image build; ingest pacing; auth/Google OAuth secrets)

**The on-server file is the source of truth.** `/work-on` and
`/setup-all` `scp` (or `cp` if running on the server) the on-server
`.env` into `work/<service>/.env` at clone time. When you sync source up
to `/home/anime/<svc>/`, **exclude `.env`** so you don't clobber the
on-server source of truth (see [deploy-loop.md](deploy-loop.md)).

Don't edit `work/<service>/.env` locally to change runtime behaviour —
your edits get overwritten on the next sync. To change a value, update
`/home/anime/<svc>/.env` on the server, then rebuild that service.

## The placeholder rule

The real Mongo/ES passwords must **never** appear in any committed file
(docs, compose templates, examples). Use the literal placeholder:

```
<stored in control .env on the server>
```

The push auto-classifier blocks any commit containing the real password.
This is a hard rule — see [safety.md](safety.md).

## How `/set-env` works

`/set-env` is the helper for editing the on-server per-service `.env`.
It edits `/home/anime/<svc>/.env` on `vast-canada-2` in place (the
source of truth), then pulls the updated file back down into
`work/<svc>/.env` so the local mirror stays consistent. After a `.env`
change you must rebuild the affected service for it to take effect
(especially the frontend, whose `NEXT_PUBLIC_BACKEND_URL` is baked at
build time):

```bash
ssh vast-canada-2 'cd /home/anime/<svc> && docker compose up -d --build'
```

## How commands read the control `.env`

Each command starts with `set -a && source .env && set +a` so the values
are available as env vars in the same shell; subsequent Bash invocations
inherit them.

## Rotation

- **GitHub PAT**: revoke at https://github.com/settings/tokens, generate
  a new one (`repo`, plus `workflow` if editing CI files), update the
  control `.env`.
- **SSH key**: rotate via `ssh-keygen` + paste the public key into
  `~/.ssh/authorized_keys` on `vast-canada-2`, update `SSH_KEY` in the
  control `.env`.
- **Mongo / ES creds**: change at the source (the on-server
  `/home/anime/<svc>/.env` + the shared data-store containers), then
  update the off-server form in the control `.env`. Both ends must
  agree. Because Mongo/ES are **shared with goongle**, coordinate any
  credential change — it affects the other project too.

## Don't

- Don't print `.env` contents in chat or command output. The GitHub
  token gives push access to the AniChan repos; the SSH key gives shell
  on the shared host.
- Don't commit `.env`. `.gitignore` blocks it; verify with `git status`
  before the first commit.
- Don't write real Mongo/ES passwords into any committed file — use the
  placeholder.

## What to do if a secret leaks

1. Rotate the GitHub PAT immediately.
2. Rotate the SSH key.
3. If Mongo/ES creds were exposed, change them on the server — and
   **coordinate with goongle**, since those stores are shared.
4. Audit recent activity in the affected repos / on the host.
