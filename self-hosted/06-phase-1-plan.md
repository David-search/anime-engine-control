# 06 · Phase 1 build plan — cache-on-play (superseded — see note)

> **⚠ Superseded / corrected (2026-06-25).** This doc's premise — *"no torrenting
> on vast.ai; tee only the HLS our proxy already fetches"* — was **wrong for our
> setup**. `vast-canada-3` is **our own** vast.ai instance and torrenting +
> storing torrents on it is **sanctioned** (verified: `transmission-daemon`
> running, a real episode pulled & served). So the conservative "cache the
> proxy's HLS only" constraint does **not** bind us — we went straight to **real
> torrent acquisition + static-HLS-at-rest** on the box. The working, measured
> result is [10-pipeline-prototype-measured.md](10-pipeline-prototype-measured.md);
> the architecture is [09-streaming-at-scale.md](09-streaming-at-scale.md). Keep
> this doc only as the record of the original (now bypassed) cache-on-play idea —
> still a valid *fallback* source (re-fetch a host's HLS) when a title is unseeded.

The original first step. **Goal:** prove the acquire→cache→serve loop and get
real GB/episode + bandwidth numbers. (Original framing assumed *"on the current
backend, tested on vast.ai, with zero new legal exposure — caches only the HLS our
proxy already fetches; no torrenting."* That constraint is lifted on our own box.)

## Scope (what Phase 1 IS / ISN'T)

- ✅ Tee the segments `watch.py` already proxies → local disk → serve our copy.
- ✅ Rank a self-hosted source first when an episode is cached.
- ✅ LRU eviction + storage cap.
- ❌ NO torrents/NZB yet (that's Phase 2, on a torrent-friendly host).
- ❌ NO new host yet (vast.ai is fine — same box, same traffic + a cache).

## Build steps

1. **`backend/app/cache.py`** — the cache layer:
   - `cache_key(anilist_id, ep, category)` → `/data/cache/{id}/{ep}/{cat}/`.
   - `is_cached(key)` / `cache_meta(key)` (size, last_access, created).
   - `warm(key, m3u8_url, referer)` — background task: fetch the playlist, fetch
     every segment + the VTTs (reuse `watch.py`'s `_fwd` referer/origin helper),
     write to disk, write a **local `index.m3u8`** whose segment URIs point at
     `/api/stream/{id}/{ep}/{cat}/seg/{n}`.
   - Concurrency-capped (reuse the semaphore pattern); dedupe in-flight warms.

2. **Serving endpoints** (`watch.py` or new `stream.py`):
   - `GET /api/stream/{id}/{ep}/{cat}/index.m3u8` → serve the local playlist.
   - `GET /api/stream/{id}/{ep}/{cat}/seg/{n}` → serve the local segment (Range-aware).
   - `GET /api/stream/{id}/{ep}/{cat}/vtt/{lang}` → local subtitle.

3. **Wire into resolution** (`sources.resolve_all` / `/watch/servers`):
   - On resolve of a clean HLS source, **enqueue `warm()`** (fire-and-forget).
   - If `is_cached(key)`, prepend **`Source 0 · AniChan (self-hosted, ad-free)`**
     pointing at the local `index.m3u8`, ranked #1.
   - Behind a flag: `SELFHOST_CACHE=1` (off by default).

4. **Eviction** — `evict()` background loop: if total cache > `CACHE_CAP_GB`,
   delete least-recently-accessed episodes until under cap. Touch `last_access`
   on serve.

5. **Metrics** — log per warm: episode, bytes stored, fetch time; expose a tiny
   `/api/stream/stats` (count, total GB, hit rate). This is the data that decides
   the production host.

## Test plan (on vast.ai)

1. Deploy with `SELFHOST_CACHE=1`, `CACHE_CAP_GB=20` (small).
2. Play an episode → confirm `warm()` runs, files land under `/data/cache/...`.
3. Reload → confirm **Source 0 appears, plays from cache, no upstream fetch**
   (watch logs: zero MegaPlay/Miruro hits on the replay).
4. Play ~20 episodes → read `/api/stream/stats`: **GB/episode**, total, and
   server **egress** while serving.
5. Exceed the cap → confirm eviction drops the coldest episodes.

## Success criteria → decision

- Cache hit serves with **0 upstream calls** and equal/better start time.
- Real numbers in hand: **avg GB/episode** (expect ~0.3–0.7 GB @1080p),
  storage growth per N plays, egress per stream.
- → Those numbers size the **production host** (storage TB + bandwidth) and tell
  us whether the FlokiNET/BuyVM-class box + budget math works. *Then* Phase 2.

## Out of scope until Phase 2+

torrent-streaming (AnimeTosho/Nyaa), the DMCA-ignored host, reverse-proxy +
Cloudflare split, the regional mesh, Whisper auto-subs / thumbnails
([05-features-unlocked.md](05-features-unlocked.md)). Don't build them yet — prove
the loop first.
