# STATE — read this first on a new session

A living snapshot of what's deployed, what's running, and what's pending. Updated at
the end of each working session. For **live** numbers run **`/startup`** (checks git +
the 6 build nodes + offshore + app health). Credentials are in [.env](.env) (gitignored).

_Last updated: 2026-06-29 — session: CDN direct-serve + Bunny token auth + CORS scope-down._

## TL;DR

**AniChan is live at https://anichan.net.** Three hosts: the **web-goongle** nginx TLS
edge → the **vast-canada-2** app host (frontend + backend + shared Mongo/ES) → the
**offshore** HLS origin. Self-hosted video now serves through a **Bunny CDN**
(`cdn.anichan.net`) with **token authentication**. A **6-node build farm** is filling
the catalog (long-tail stretch; ~984 eps / 148 anime at last check).

## What's LIVE / deployed (verified this session)

- **App + domain:** `https://anichan.net` (web-goongle edge `66.55.65.89` → canada-2
  `:43879` app / `:43577` api). Every API route is under `/api`.
- **Self-host video → CDN:** build farm → offshore (`185.255.120.59`, nginx `/srv/hls`)
  → **Bunny pull-zone `cdn.anichan.net`** → backend auto-serves the `★ AniChan` source1.
  - Backend env (canada-2 `/home/anime/backend/.env`): `SELFHOST_CDN_BASE=https://cdn.anichan.net`,
    `SELFHOST_CDN_TOKEN_KEY=<Bunny token key, in control .env>`, `SELFHOST_CDN_TTL=43200`.
  - Heavy bytes (segments/subs/fonts) serve **direct from Bunny, token-signed**; only the
    KB-sized playlists proxy through canada-2. **Verified:** headless playback ✅, cache
    MISS→HIT ✅, signed segment 200 / unsigned 403 ✅.
  - Design + rationale: [self-hosted/19-cdn-token-auth-and-hardening.md](self-hosted/19-cdn-token-auth-and-hardening.md).
- **CORS:** backend `CORS_ORIGINS=https://anichan.net,https://www.anichan.net,http://localhost:3000`
  (was `*`). Other sites' browser-JS can't read the API; scrapers still can (CORS is not a scraper defense).
- **Backend repo** `anime-engine-backend` @ `main` — all session changes pushed
  (`watch.py` `_emit`/`_sign`, `config.py` `SELFHOST_CDN_*`, compose env). vast-canada-2 is current.

## Build-farm fill (run `/startup` or `/farm-status` for live)

- 6 nodes `canada-2..7`, 3 Eweka accounts. Last sweep: **984 eps / 148 anime**, ~1.2 TB
  of the 16 TB cap (15 TB free).
- **Long-tail stretch**: ~20 eps/cycle. Popular/NZB-easy titles are done; the remainder
  are torrent-only → slow **live-Nyaa recovery**. Realistic ETA ~6–9 days for full target.
- **Disk stays bounded** (ship-and-delete works; AV1-skip + ≤3GB fix holds). Occasional
  manual nzbget revivals (c3/c4 history) — pattern's been quiet (5 clean cycles).
- Ops: [self-hosted/RUNBOOK.md](self-hosted/RUNBOOK.md).

## PENDING — not done, waiting on the user (don't do unprompted)

- [ ] **OFFSHORE BACKUP MIRROR** ⚠️ — offshore is a single point of failure (~1.2 TB now →
      ~10 TB). If it dies, the served library is lost (re-derivable by re-running the fill,
      but weeks + $$). **Recommend:** rsync `/srv/hls` → a 2nd cheap host (Hetzner Storage
      Box ~€24/mo 10TB, Backblaze B2 ~$60/mo, or a 2nd DMCA-ignored VPS = safest) + optional
      **Bunny origin-failover**. Claude can wire the rsync + failover once the user picks a target.
- [ ] **CLOUDFLARE for API rate-limit / bot protection** — user prefers CF over an in-app
      limiter. Path: move `anichan.net` DNS to Cloudflare, **🟠 orange-cloud `anichan.net`**
      (app+API → CF WAF/rate-limit, hides edge IP), **⚫ GRAY-cloud `cdn.anichan.net`** (video
      MUST bypass CF — its video ToS + keep Bunny cache/token-auth). Needs the user's CF
      account + DNS move; then Claude helps set rules + switch the backend's client-IP source
      to `CF-Connecting-IP`. **Why Bunny token auth still matters even with CF:** the CDN is
      gray-clouded, so CF never sees the video — only Bunny's token auth protects the CDN path.
- [ ] **In-app API rate-limit** — superseded by the Cloudflare plan; don't build it.
- [ ] **`ensure_up.sh` hardening** — auto-revive nzbget when the process dies but its tmux
      session lives (cron watchdog currently only checks session existence). Proposed, **UNAPPROVED**.
- [ ] **Control-plane doc parity** — keep CLAUDE.md / infrastructure.md / RUNBOOK in sync as
      the above land.

## Key pointers

- **Credentials:** [.env](.env) (gitignored) — Bunny token key, Eweka ×3, offshore, ingest token, build nodes.
- **Orientation/ops:** this file · [self-hosted/RUNBOOK.md](self-hosted/RUNBOOK.md) (build farm) ·
  [self-hosted/19-cdn-token-auth-and-hardening.md](self-hosted/19-cdn-token-auth-and-hardening.md) (CDN + anti-scrape).
- **Commands:** `/startup` (full state check), `/farm-status` `/farm-fix` `/farm-provision`,
  `/work-on` `/deploy-backend` `/deploy-frontend`, `/probe-es` `/probe-mongo` `/tail-logs`.
