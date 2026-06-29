# CDN direct-serve, token auth, and the anti-scrape model (as-built + plans)

How the self-hosted video gets from the offshore origin to viewers cheaply and safely,
and the security model around it. Builds on the proxy serving in
[15-asbuilt-ingest-and-serving.md](15-asbuilt-ingest-and-serving.md) and
[16-asbuilt-backend-frontend.md](16-asbuilt-backend-frontend.md). **Deployed + verified
2026-06-29.**

## 1. Why a CDN (the problem it solves)

Before: every self-hosted segment proxied **through canada-2** (`/api/watch/seg`). The
origin IP stayed hidden, but **all video bytes flowed through a metered vast.ai box** —
expensive (per-GB egress) and a bottleneck at scale. Video is heavy (~0.5 GB per 24-min
episode at ABR); production traffic on vast egress is the wrong place for it.

After: a **Bunny CDN pull-zone** in front of the offshore origin serves the heavy bytes
direct to viewers, edge-cached, with the origin IP still hidden. canada-2 drops out of
the byte path almost entirely.

## 2. Topology

```
browser ──/api/watch/servers──► backend (canada-2)        signs + returns urls
        ──/api/watch/m3u8──────► backend proxies master + a0/a1/v0 playlists (KB each)
                                  └ rewrites every child → cdn.anichan.net/...?token=…&expires=…
        ──segments/subs/fonts──► cdn.anichan.net (Bunny edge)   ← ~99% of bytes, token-signed
                                  └ cache HIT → serve; MISS → pull from offshore (185.255.120.59)
                                  └ origin IP hidden; token invalid → 403
```

- **DNS:** `cdn.anichan.net` (GoDaddy) → CNAME `anichan.b-cdn.net` → Bunny edge. Force SSL on.
- **Bunny pull zone:** Origin URL `http://185.255.120.59` (HTTP is fine — Bunny terminates
  HTTPS at the edge, pulls origin over HTTP). Host header blank (offshore serves the default
  vhost). Standard tier to start; switch to **High-Volume tier** (~$0.005/GB, fewer PoPs) once
  real volume justifies it. Region toggles to cap cost (keep EU+NA+Asia).
- **Cost:** pay-per-GB delivered (~$0.01/GB EU/NA), ~$0 until launch (no traffic). Cache offload
  means offshore only serves the thin cache-fill. Set a Bunny spend cap.

## 3. The HLS relative-URL catch (why playlists proxy)

HLS segment URLs inside playlists are **relative** (`seg000.ts`), so they don't carry a
query string — signing the master alone wouldn't authorize its segments, and a bare
direct-CDN master would let segments resolve to **unsigned** CDN URLs (→ 403 under token
auth, or open enumeration without it). Fix: **proxy the small playlists** (master +
`a0/a1/v0` variant lists, KB each) through `/api/watch/m3u8` so the backend rewrites each
child to an **absolute, token-signed** CDN URL; the heavy leaf files (segments, subtitles,
fonts) go **direct + signed**. ~99% of bytes still offload; only KB playlists touch canada-2.

Implemented in [backend `app/routers/watch.py`](../repos/backend/CLAUDE.md):
- `_emit(kind, url, ref)`: for self-host-origin URLs, **playlists (`kind=="m3u8"`) → `_proxy()`**
  (so their children get rewritten/signed + the master's subtitle groups stripped); **leaf files
  → `_sign(cdn_url)`** (direct CDN). Non-self-host (Miruro) or no-CDN → falls back to `_proxy()`.
- `_sign(cdn_url)`: Bunny token = `sha256_b64url(KEY + path + expires)` → `?token=…&expires=…`.
  No IP binding (would break mobile/dual-stack). No-op when the key is unset.
- Env (canada-2 `/home/anime/backend/.env`): `SELFHOST_CDN_BASE`, `SELFHOST_CDN_TOKEN_KEY`
  (Bunny Token Auth key — secret, also in control `.env`), `SELFHOST_CDN_TTL=43200` (12 h).

**Verified:** headless-browser playback (currentTime advances, a0+v0 segments load from CDN,
0×403), cache MISS→HIT across different tokens (per-viewer token doesn't bust the cache —
Bunny strips it from the cache key), signed segment 200 / unsigned 403, signed subtitle 200.

## 4. Bunny config knobs (set on the pull zone)

- **Token Authentication: ON**, key in `SELFHOST_CDN_TOKEN_KEY`. **IP validation: OFF**
  (breaks mobile IP changes + IPv4/IPv6 mismatch between the API call and the CDN fetch).
- **Block root path access: ON**, **Block POST: ON** — harmless hardening (viewers only GET files).
- **Force SSL: ON** on both hostnames (site is HTTPS → segments must be too, else mixed-content).
- Keep **both** linked hostnames: `cdn.anichan.net` (serve from) + system `anichan.b-cdn.net`
  (the CNAME target — don't delete it).

## 5. The anti-scrape model (what each layer protects)

**Token auth stops direct-CDN enumeration + hotlinking, NOT API scraping.** The threat model:

| Door | Path | Protected by |
|------|------|--------------|
| **CDN** `cdn.anichan.net/...` | browser → Bunny (bypasses the app) | **Bunny token auth** — unforgeable (needs the secret key), 12 h expiry, path-scoped → guessed/leaked URLs 403 |
| **API** `anichan.net/api/...` | browser → edge → backend | **Cloudflare** (planned) / rate-limit / auth |

- **What token auth fixed:** nobody can iterate `cdn.anichan.net/{id}/{ep}/...` to mirror the
  library, nobody can embed your streams (links expire), origin stays hidden.
- **The remaining gap — API scraping:** `/api/watch/servers?anilistId=X&ep=Y` is **public** and
  hands a freshly-signed URL to anyone (your anonymous viewers *are* "anyone"). A scraper can
  automate it across the catalog, follow the signed URLs, and download — using your backend as a
  signing oracle. Token auth **forced them through the API** (a chokepoint), but doesn't close it.
- **CORS is not a defense.** It's a *browser* mechanism that protects users, not the server —
  curl/scripts ignore it; `Origin`/`Referer` are spoofable. We scoped `CORS_ORIGINS` to
  `https://anichan.net` anyway (stops *other sites'* browser-JS from reading the API), but a
  scraper still gets 200 + data.
- **Fundamental:** anything playable is rippable (no DRM). The goal is slow + detectable, not impossible.

## 6. Planned hardening (NOT done — see STATE.md PENDING)

- **Cloudflare** in front of the **API** for rate-limit/bot (user-preferred over an in-app limiter):
  move `anichan.net` DNS to CF, **🟠 orange-cloud `anichan.net`** (app+API → WAF/rate-limit, hides
  the edge IP), **⚫ GRAY-cloud `cdn.anichan.net`** (video MUST bypass CF — its no-large-video ToS,
  and to keep Bunny's cache + token auth). **Bunny token auth is still required even with CF**,
  precisely because the gray-clouded CDN never passes through Cloudflare — only Bunny can guard the
  video path. With CF live, switch the backend's client-IP source to `CF-Connecting-IP` if any
  in-app IP logic is added. Rate-limit `/api/watch/servers`; optionally require login + Turnstile.
- **Offshore backup mirror** (the single-point-of-failure fix) — rsync `/srv/hls` to a 2nd cheap
  host + optional Bunny origin-failover. See STATE.md.

## 7. Resilience / swap-out

Offshore is the **source of truth**; Bunny is a **swappable cache**. If Bunny suspends the zone
(it's DMCA-compliant): blank `SELFHOST_CDN_BASE` (instant proxy fallback) or re-point the
`cdn.anichan.net` CNAME at another CDN/origin — minutes, no redeploy, nothing lost. That's why the
backend emits `cdn.anichan.net` (your domain), not `anichan.b-cdn.net` (Bunny's host).

Related memory: `streaming-source-miruro`, `self-hosted-direction`.
