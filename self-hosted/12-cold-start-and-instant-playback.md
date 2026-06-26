# 12 · Cold-start & instant playback — how top sites really do it

Decision-grade research (7-agent workflow + adversarial verify; central thesis
**SOUND**, every load-bearing fact independently confirmed). Answers: *how do top
sites make playback instant, and what's the best way for AniChan?*

## The myth-buster

**Top sites do NOT torrent-stream the video to you on play.** "Instant" is almost
always **fetching a pre-encoded `.m3u8` over HTTP Range** — someone already
encoded it. (Confirmed across all tiers.)

| Tier | How "instant" actually happens | Torrent on hot path? |
|------|--------------------------------|----------------------|
| Aggregators (HiAnime, Miruro) | scrape an embed host (MegaCloud/VidCloud/MegaPlay) that **already holds pre-encoded HLS on a CDN** | **no** |
| Cache-on-play (ANIMO) | first viewer = **scrape fallback (megaplay)**; torrent caches segments for the **2nd** viewer | no (cold) |
| Bulk self-host (2dhive ~19 TB) | **pre-encode the whole library offline**, serve static HLS — no cold start exists | no |
| Stremio + debrid | the only real piece-streaming; but "instant" = **debrid cache hit** (pre-downloaded); uncached is the slow path everyone avoids | only when slow |

The durable pattern everyone converges on: **pre-encode an ABR ladder at rest →
static HLS/CMAF over HTTP Range from a CDN → engineer cold-start away by
pre-positioning the predicted-popular catalog before anyone asks** (Netflix Open
Connect fills caches nightly on a popularity forecast — confirmed). Anime is
*extra* tractable: the hot set is **published in advance** (AniChart/AnimeSchedule),
and popularity is heavily skewed (a small known slate captures most plays).

## Lever ranking for us (verified)

1. **🥇 Pre-cache the airing/popular slate** — the biggest lever by far. Makes
   cold-start *rare*, not merely *fast*. NVENC makes the encode ≈ free (measured
   583× remux); **egress** is the only cost that scales. **Build first.**
2. **🥈 Miruro host-HLS cover** — already built; instant cover for residual cold
   seconds (just-aired / true long-tail).
3. **🥉 Progressive torrent-stream-on-play** — real but **narrow**: the right tool
   for ONE job — give the first viewer of a *genuine cold long-tail* episode a
   self-hosted stream while **minting the static segments**. An **ingest primitive,
   never a serving model.**
4. **❌ Debrid — do not adopt.** Contradicts "own the bytes"; **May 2026 Real-Debrid
   keyword-deleted cached files, users lost 50–70%** (confirmed). Useful only as a
   conceptual proof that "pre-download once, serve a plain file to all" = our plan.

```
open cold episode E
 ├─ in pre-warmed slate? → static HLS (Source 1). DONE.        [#1 — common case]
 └─ no (long-tail / just-aired):
      ├─ Miruro NOW (<2s)                                       [#2 — instant cover]
      └─ background: torrent-stream-on-play → mint static HLS   [#3 — self-hosted after]
```

## Torrent-stream-on-play — the right way to build it (when we do, Phase 3)

We proved a non-seekable pipe → HLS EVENT works (229 segs). **The key upgrade,
from Webtor.io (MIT, the closest open-source reference — confirmed real):**

- **Serve the still-downloading file over HTTP Range and feed ffmpeg `-i <url>
  -seekable 1`** instead of a pipe — fixes MKV cues-at-end / no-duration / no-seek.
  Lift its **`torrent-web-seeder`** (range-over-reader + readahead + LRU piece
  evict), **`content-transcoder`** HLS recipe (per-stream `-f segment`, `-c:v copy`
  when h264), **`warmup` SSE** (head-prefetch on page-open), **`RunManager`**
  seek-quantum sharing (concurrent first-viewers share one ffmpeg).
- libtorrent **`set_piece_deadline()`** for piece scheduling (its docs say
  `sequential_download` is suboptimal for streaming) — but **keep `sequential_download
  + piece_priority` as fallback** (set_piece_deadline has a known regression #5891).
- **Codec split:** H.264 → `-c:v copy` (free); HEVC/10-bit → NVENC→H.264 (HEVC must
  be fMP4 not TS; raw MKV/HEVC unplayable in browsers — confirmed).
- **Subtitles:** ASS→WebVTT loses all styling (confirmed) → ship **styled ASS
  sidecar + JASSUB/SubtitlesOctopus client-side** (no per-viewer burn-in).
- **live→VOD→promote:** on completion add `#EXT-X-ENDLIST`, build the ladder +
  extract all subs, mark Source 1. The cold episode is self-hosted forever after.
- **Lift from Seanime: ingest only** (`torrents/analyzer`, `habari` parser,
  transmission RPC `FilesUnwanted`), NOT its per-viewer serving runtime.

## Phased plan

- **Phase 0 (done):** Miruro cover; HLS-at-rest; nginx Range; AniList→AnimeTosho
  ingest + auto-trigger; deployed Source-1 integration; pipe→HLS-EVENT prototype.
- **Phase 1 — Pre-cache worker (BUILD FIRST):** airing/trending calendar → auto
  pull 1080p H.264 MultiSub on air → `hls_build.py` → pre-position before first
  view. `precache.py` feeds the bounded `ingest_api` queue. *Makes the slate never cold.*
- **Phase 2 — Edge cache + origin shield:** CDN/edge mesh in front of nginx (long
  TTL, immutable, `proxy_cache_lock`, `background_update`); CMAF packaging. *Ship here.*
- **Phase 3 — Harden torrent-stream-on-play** (Webtor-style HTTP-range seeder +
  `set_piece_deadline` + the lifts) for the long tail; background-mint static,
  Miruro covers the first seconds. **Core PROVEN** (`stream.py`): a cold torrent →
  **first playable HLS segment in ~5 s** (at 2% downloaded), plays video+audio
  while streaming (libtorrent HTTP-Range seeker → ffmpeg `-seekable 1` remux →
  EVENT HLS → ENDLIST on finish; H.264=copy, HEVC=NVENC). *Remaining: wire it into
  the cold-episode flow (serve the in-progress master as ★ AniChan; finalize →
  full ladder+subs on completion).*
- **Phase 4 — Faithful subs (JASSUB) + multi-audio renditions.**

## Caveats (from the adversarial verify)
- The exact Zipf percentages ("top 10% = ~49%") and a cloud-encode $ figure are
  **illustrative, not measured** — they don't change the conclusion (the
  *qualitative* concentration + published-in-advance slate is what carries it).
- Keep the libtorrent `sequential_download` fallback (the deadline API can regress).

**Bottom line:** pre-cache the predictable slate (Phase 1) + edge cache (Phase 2)
gives near-instant playback for the large majority of plays, all self-hosted, with
the least effort/risk. Torrent-stream-on-play is the finite tool for the long tail —
built last, in the background, never on the hot path.
