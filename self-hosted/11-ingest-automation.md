# 11 · Ingest automation — the headless library-filler (built + measured)

The **video-origin worker** that fills the cache automatically: `AniList id →
AniDB → discover → map-to-episode → download → hls_build → register`. Runs on the
video node only (NOT the clean backend — see [09](09-streaming-at-scale.md)).
Built + validated across 8 diverse anime on `vast-canada-3`.

## Files (on the box at `/data/`, mirrored in `claude/self-hosted/`)

| File | Role |
|------|------|
| [`ingest.py`](ingest.py) | orchestrator + CLI (discover / map / select / download / register) |
| [`cache_db.py`](cache_db.py) | SQLite cache index + LRU eviction (pin, empty-dir cleanup) |
| [`relparser.py`](relparser.py) | **ported Amatsu parser** (season-aware episode extraction) |
| [`hls_build.py`](hls_build.py) | the doc-10 HLS-at-rest builder (called per episode) |

CLI: `ingest.py {episode <id> <ep> | series <id> [--eps 1-12] [--require-complete]
| coverage <id> | stats | evict <gb> | reindex} [--dry-run] [--no-hevc]`.

## The hard problem it solves: torrent → *correct* episode

The fragile part is **not** download/transcode — it's matching a chaotic fansub
release to the right AniList episode without ever serving the **wrong** or a
**partial** season. Three real traps (all hit + handled):

- **Absolute vs season numbering** — "One Piece - 1085" (absolute) vs "S2E01".
- **TVDB season relabel** — VARYG/ToonsHub file a *sequel* as `S01E12`; that's
  AniList **S2**E12, not S1E12. (The 2025 S1 and 2026 S2 share the title.)
- **Just-aired lag + back-catalog** — AnimeTosho hasn't AniDB-mapped this week's
  episode yet; a 1000-episode show can't be found by single-episode search.

## Discovery — tiered, multi-source

1. **AnimeTosho `aid`** (AniDB-mapped) — authoritative; releases carry `anidb_eid`.
2. **AnimeTosho keyword** (`q=`, cleaned title variants) — fills un-mapped.
3. **AnimeTosho batch** (`q=<title> batch`) — season packs / long-running back-catalog.
4. **Nyaa.si RSS** (`?page=rss`) — **just-aired episodes AnimeTosho hasn't indexed**
   (verified: finds SubsPlease/ToonsHub the same day) + Nyaa batches.

Deduped across sources by **info-hash**. Nyaa is reachable from the box (no
Cloudflare block here); `nyaaapi.onrender.com` is the documented JSON fallback if
an origin IP is 403'd.

## Mapping — authoritative first, then *guarded* fallback, never a guess

`map_episode()` returns `(episode, confidence)` or `(None, None)` — confidence
ranked **eid > sxxeyy > absolute > airdate > parsed**:

1. **`eid`** — AnimeTosho `anidb_eid` → ani.zip episode. Exact, zero parsing.
2. **`sxxeyy`** — `SxxEyy` whose season **matches** the AniList season.
3. **`absolute`** — bare/continuous number resolved via ani.zip `absoluteEpisodeNumber`
   (handles "S01E19" = absolute 19 = S2E07).
4. **`airdate`** — a TVDB **S01 relabel** of a sequel, *confirmed* by matching the
   release's publish date to ani.zip's episode airdate (±45 d). This is what
   distinguishes a 2026 `S01E12` (= S2E12, accept) from a 2025 `S01E12` (= S1E12,
   reject).
5. else → **reject** (becomes a reported gap, never a wrong pick). Cross-season
   (`S03E04` for an S2 request) is dropped outright.

**Batches:** `map_batch()` resolves a pack's episode **range** (via `get_batch_range`
+ absolute resolution); `download_batch_file()` adds the pack, **deselects every
file**, then downloads **only** the requested episode's file (Amatsu
`select_best_video_file` + transmission `-G all` / `-g <idx>`) — so a 143 GB One
Piece pack costs one ~200 MB file, not 143 GB.

## Completeness gate — honest, per the "never partial" rule

`coverage()` reports, for every episode 1..N: **covered** (strong single) /
**batch_only** (extract one file) / **weak** (parsed-only) / **gap** (no source).
`complete` is true only when every episode is obtainable via a strong single or a
batch. `series --require-complete` refuses to ingest a season with a true gap.

## Validated — cross-anime coverage (the robustness proof)

| Anime | Shape | Coverage | Notes |
|-------|-------|----------|-------|
| JJK S2 | sequel, abs offset 24 | **23/23 ✓** | eid-dominant |
| AoT S1 | classic finished | **25/25 ✓** | |
| Your Name / A Silent Voice | movies | **✓** | single-file |
| Steins;Gate | TV + movie sequel | **24/24 ✓** | |
| **TBATE S2** | just-finished sequel, S1/S2 title collision | **12/12 ✓** | eps 7-12 via **Nyaa**; 2025 S1 rejected by airdate |
| **Frieren S1** | premiere-block batch | **28/28 ✓** | eps 2,3 via **batch** |
| **One Piece** | 1172 eps | **1160/1172** | 1135 via batch packs; only the ~12 newest gap (single-ep, just-aired) |

The mapping core is **eid-anchored and robust**; the earlier fragility was purely
**discovery**, closed by the Nyaa tier (just-aired) + batch tier (back-catalog).

## Known limits / next

- One Piece's ~12 newest episodes (no batch yet) need the single-ep Nyaa tier to
  reach deeper / dedup better — minor.
- Per-file batch download relies on transmission metadata + the ported
  `select_best_video_file`; movies-in-a-pack and odd file layouts may need tuning.

## Backend + frontend integration (wired, behind a flag)

The clean backend now offers the self-hosted cache as **Source 1** when present:
- **`backend/app/config.py`** — `SELFHOST_CACHE` (flag) + `SELFHOST_ORIGIN` (video-origin base URL).
- **`backend/app/sources.py`** — `_selfhost_source()` probes
  `{ORIGIN}/{anilistId}/{ep}/{cat}/master.m3u8`; on hit, parses the subtitle
  tracks and returns an HLS source **prepended** in `resolve_all()` (ranked #1).
- **`backend/app/routers/watch.py`** — the `/m3u8` proxy now rewrites
  `EXT-X-MEDIA` **audio** group URIs (so separate-audio HLS plays) and drops the
  in-manifest **subtitle** group (subs go via the player's `<track>` array). The
  browser only ever sees `/api/watch/...` URLs — **origin IP stays hidden**.
- **`frontend/components/WatchPanel.tsx`** — the self-hosted source shows as
  **★ AniChan** (ad-free); otherwise the player consumes it transparently
  (HLS + quality menu + 9-language subtitle menu).
- The video origin (test box) is exposed on a vast-mapped port:
  `http://159.48.242.1:35346` → set `SELFHOST_ORIGIN` to it.

### Deployed live (2026-06-25) + auto-ingest + reviewed

**LIVE on `anichan.net`.** Verified in real Chrome (Playwright): ★ AniChan plays
ep4 — 1080p video + Japanese audio (separate audio group works) + 9-language
subtitle menu, no fatal hls.js error, segments `206` on Range.

**Auto-ingest on page open:** `/servers` fire-and-forgets a trigger to a small
**ingest API** on the video node (`/data/ingest_api.py`, tmux, `:8001` → public
`:35147`): caches the opened episode + 1 prefetch. Safeguards — shared-secret
auth (`X-Ingest-Token`), bounded work queue + fixed worker pool, dedup vs
cached/in-flight, already-cached → `touch()` (keep-warm / anti-evict), LRU-evict
to `CACHE_CAP_GB`. Backend env: `SELFHOST_INGEST_URL`, `SELFHOST_INGEST_TOKEN`.
Miruro covers the gap instantly while a cold episode builds in the background.

**Adversarial bug review** (35-agent workflow, 19 confirmed) — fixed: SSRF guard
hardened (resolve host, reject private/loopback/link-local/metadata; closes
octal/decimal/hex-literal bypasses); fire-and-forget task GC (strong ref); ingest
API threading (bounded queue + worker pool + evict timeout + lock-safe); mid-play
eviction (touch-on-watch); self-host probe cached separately (no 3-min stale
negative, runs concurrent with Miruro — no added latency); `_sub_label` (readable
names, drops dedup-number artifacts); `/m3u8` EXT-X-MEDIA edge cases. Known
residual: DNS-rebinding TOCTOU on the proxy (needs IP-pinned transport); dub
category falls back to Miruro (self-host package is built under `sub`).

Edge nginx (`anichan.net`): `/api/` → backend, dedicated `/api/watch/` stream
block (no buffering, Range, long timeouts). Next: add `proxy_cache` to
`/api/watch/seg` (the edge-cache scaling lever from doc 09).
