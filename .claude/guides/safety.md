# Safety — what to NOT do, and why

The control repo builds + deploys the two AniChan services to the app host
(vast-canada-2), which sits behind the **web-goongle nginx edge** and is
backed by a self-host **build farm** + **offshore** HLS origin; it probes
the data layers read-only and stops there. Two things drive most of the
caution: the Mongo/ES data stores **and** the nginx edge are **shared**
with a separate goongle project. This file lists the boundaries and reasoning.

## Hard rules

| Rule | Why |
|---|---|
| **Never drop the ES `anime` index without explicit user confirmation.** | It's the entire search/suggest layer. Recreating it means a full re-index from the ingest job. Confirm first. |
| **Never drop / wipe the Mongo `anime_db` (or its `anime` collection) without explicit user confirmation.** | It's the source of truth for the running app — catalog, users, comments, likes, history. A full catalog rebuild from AniList is paced (~2.2 s/req, ~30 req/min degraded) and takes hours. |
| **Mongo and ES are SHARED with the goongle project on the same host. NEVER touch goongle's `rfp_db` or any non-`anime` index/collection.** | AniChan owns `anime_db` (Mongo) and the `anime` index (ES) only. Dropping or mutating goongle's `rfp_db` / other indices breaks an unrelated production system. Always scope ops to `anime_db` / `anime`. |
| **Never commit real Mongo/ES passwords.** | Use the literal placeholder `<stored in control .env on the server>`. The push auto-classifier blocks commits containing the real password. See [secrets.md](secrets.md). |
| **Ask before restarting / recreating containers.** | `mongodb` and `elasticsearch` are shared; restarting them affects goongle too. Confirm before `docker restart` / `docker compose up` on a shared container. The two `anime-*` containers are AniChan-only, but still confirm if unsure. |
| **Don't `docker rm` / `docker volume rm`.** | Same data-loss + shared-infra risk. Use `docker compose up -d --build` to recreate the AniChan service containers; never remove the Mongo/ES volumes. |
| **The web-goongle nginx edge is SHARED — it also serves `goongle.net`.** Only edit the `anichan.net` vhost; never reload/restart nginx or touch other vhosts without scoping (`nginx -t` first). | A bad reload or an edit to a shared/other vhost can 502 goongle's production site. The edge (`web-goongle` alias, password auth) is what makes `https://anichan.net` work. |
| **Don't wipe the offshore `/srv/hls` origin (or its per-anime dirs) without confirmation.** | It's the entire self-hosted video catalog — hundreds of shipped episodes (~hours of build-farm work each). Cleaning a *build node's* working dirs (`/data/...`, via `/farm-fix … clean`) is safe — they re-download; deleting from offshore is not. |

**These are enforced, not just guidance.** [.claude/settings.json](../settings.json)'s
deny-list auto-blocks (before execution, including ssh-wrapped variants):
`rm -rf`, every `git push --force` form, `docker restart` / `docker exec` /
`docker rm` / `docker volume rm` against the shared `mongodb`/`elasticsearch`
containers, `curl -X DELETE` vs the ES `anime` index or Mongo, and any
`dropDatabase`. The deny-list is a backstop — the rules above are still your
responsibility — but those specific footguns get rejected even if invoked
by accident.

## Soft rules

- **Read-only probes are unrestricted.** Counting docs, reading a
  catalog entry, `GET`-ing search results, tailing logs — fine, no
  confirm. Scope them to `anime_db` / the `anime` index.
- **Edit → build-on-server is the default flow.** Sync source to
  `/home/anime/<svc>/`, `docker compose up -d --build`, verify the
  public URL. No prompts for the two `anime-*` services themselves.
- **The catalog read path is pure Mongo/ES.** After a backend change,
  confirm `/api/catalog/trending` and `/api/search?q=...` still return —
  that's the contract. (Every route is under `/api`; the public path is
  `https://anichan.net/api/...` through the edge.)

## AniList rate-limit hygiene

- The **only** AniList caller is `scripts/ingest.py` (paced ~2.2 s/req).
  AniList caps offset pagination at 5000 entries and degrades to
  ~30 req/min. Don't add per-request AniList calls to the serving path —
  the one allowed exception is `/api/catalog/trending` (cached 30 min).
- Don't run two ingest jobs concurrently against AniList; you'll trip
  the rate limiter and degrade both.

## Disk / shared-host heuristics

- The host carries both AniChan and goongle workloads, plus shared
  Mongo / ES / (goongle's) Qdrant. Be deliberate about disk before a
  large ingest sweep — a `full` run materialises the whole catalog into
  both Mongo and ES.
- `docker system prune -af` on this host clears images for **both**
  projects — only run it deliberately, and never with `--volumes`
  (that would nuke the shared Mongo/ES data volumes).

## Secrets hygiene

- The real Mongo/ES passwords live ONLY in the on-server control `.env`.
  Never echo `.env` contents in command output; source it
  (`set -a; source .env; set +a`) and use the variables.
- The `GITHUB_TOKEN` in `.env` has push access to the AniChan repos. If
  you suspect it leaked, revoke at https://github.com/settings/tokens
  and rotate the local file.

## When to ask before doing

If you're about to do something destructive the auto-classifier /
deny-list doesn't catch — especially anything that could touch the
**shared** Mongo/ES, drop an index/collection, or restart a shared
container — pause and confirm with the user. The cost of asking is one
round-trip; the cost of an unwanted destructive op on shared infra is
hours of recovery and collateral damage to the goongle project.
