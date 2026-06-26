# Streaming pipeline & player (as built)

How AniChan actually resolves and plays episodes today. This is the
implemented counterpart to the teardown in
[post-hianime-landscape-and-miruro.md](post-hianime-landscape-and-miruro.md):
that doc explains *why* Miruro's aggregator is the source; this one documents
the *shipped* resolver, proxy, source curation, and player.

## TL;DR pipeline

```
AniList id ──► Miruro secure pipe ──► curated hosts ──► our /api/watch proxy ──► hls.js player
   (catalog)      (episodes+sources)    (5 sources)        (m3u8/seg/vtt)         (or host iframe)
```

- **One backend module** (`app/sources.py`) speaks Miruro's `secure/pipe`
  protocol and abstracts its rotating provider codenames into stable,
  host-keyed sources.
- **One router** (`app/routers/watch.py`) exposes `/episodes`, `/servers`,
  `/sources`, and proxies the HLS playlist, segments, and subtitles with the
  per-stream `Referer`/`Origin` the CDNs require.
- **One player** (`components/Player.tsx`) plays the proxied HLS/MP4 with
  quality + multi-language subtitle selectors; **embed** sources fall back to
  the host's own iframe (`components/HostEmbed.tsx`).

## Miruro secure-pipe protocol (verified live)

```
GET {base}/api/secure/pipe?e={base64url(json)}
  request envelope: {"path","method":"GET","query":{…},"body":null,"version":"0.1.0"}
  response: base64url -> gzip -> JSON
```

| path        | query                                          | returns                |
|-------------|------------------------------------------------|------------------------|
| `episodes`  | `anilistId`                                    | `{mappings, providers}` |
| `sources`   | `episodeId, provider, category, anilistId`     | `{streams, subtitles}`  |

**Load-bearing gotcha:** `episodeId` is already base64 — pass it **as-is**.
Re-encoding it returns HTTP 444. Base domains rotate (`MIRURO_BASES`: `.bz`
works, `.online` is dead from our IP); the resolver iterates them.

### Rate-limit defenses (the "we got 429 with zero users" fix)

Three layers, all in `sources.py`:

| Defense                       | Mechanism                                                       |
|-------------------------------|----------------------------------------------------------------|
| Global concurrency cap        | `_PIPE_SEM = asyncio.Semaphore(4)` — every pipe call (live **and** ingest) funnels through it |
| Episodes cache                | `_ep_cache` per `anilistId`, 10-min TTL (episode lists are stable) |
| Resolved-server cache         | `_servers_cache` per `(anilistId, ep, category)`, 3-min TTL — a hot episode resolves **once** per window, shared across all users |
| Gentle ingest                 | availability stamp runs at concurrency 2, 0.5 s delay          |

## Curated sources (`RELIABLE_SOURCES`)

Only hosts that measurably **play**, one source per host, flat numbered list
(`source1..sourceN`), clean (our ad-free proxied player) first, embeds last:

| # | host       | mode  | notes                                             |
|---|------------|-------|---------------------------------------------------|
| 1 | `animedao` | clean | **most stable** clean HLS — promoted to source1 (least buffering) |
| 2 | `anidbapp` | clean | clean HLS                                          |
| 3 | `animegg`  | clean | clean MP4                                          |
| 4 | `allmanga` | embed | biggest library + dub; clean flaky → embed         |
| 5 | `anikoto`  | embed | HiAnime / MegaPlay → embed                          |

- `LABEL_TO_HOST` maps `source1..N` to the host (not Miruro's codenames,
  which rotate: bonk/ally/pewe/…).
- `BLOCKED_EMBEDS = ["ok.ru"]` — region-locked to Russia (`movieBlocked`
  elsewhere, incl. CIS); excluded declaratively.
- `resolve_all()` has **mode-fallback**: a host that has the episode is never
  dropped just for lacking its preferred stream type.

## The proxy (`app/routers/watch.py`)

- `_fwd(ref)` injects **both** `Referer` and `Origin` (derived from the
  referer) — many segment CDNs 400/401 without `Origin` even when the playlist
  fetched fine.
- `m3u8` rewrites every variant/segment/`EXT-X-KEY` URI to root-relative
  `/api/watch/seg|m3u8` proxy paths; `seg` is Range-aware; `vtt` tries multiple
  referers and validates `WEBVTT` in the first 64 bytes (a broken track never
  blocks playback).
- SSRF guard (`_safe`): https/http only, no localhost/private/link-local.

## The player (`components/Player.tsx`)

```ts
if (kind === "mp4") video.src = stream;
else if (Hls.isSupported()) { /* hls.js — MUST be checked first */ }
else if (video.canPlayType("application/vnd.apple.mpegurl")) video.src = stream; // Safari only
```

**Critical ordering bug (fixed):** `Hls.isSupported()` must come **before**
`canPlayType`. Some Chrome builds answer `"maybe"` for native HLS but then fail
with `MEDIA_ERR_SRC_NOT_SUPPORTED` (error code 4), and going native also
bypasses hls.js's quality-level detection. Verified with headless Chrome:
both sources play, quality menu (1080/720/360) and a 9-language subtitle menu
appear.

Player features: quality `<select>` over `hls.levels`; subtitle `<select>`
toggling `textTracks[i].mode`; big centred gradient play button until the
`playing` event; **8-second stall watchdog** that calls `onError()` if playback
never starts (auto-skip a dead source).

### Embeds (`components/HostEmbed.tsx`)

No `sandbox` attribute — host players actively detect it ("Oops! Sandboxed our
player is not allowed") and refuse to run even with `allow-popups`. Trade-off
accepted: embed sources carry the host's own ads; the clean sources stay
ad-free.

## Subtitle reality

Subtitle tracks are whatever Miruro returns **per provider per anime**:
new simulcasts (e.g. Dr. Stone) carry 5–9 language VTTs; classics (e.g. Code
Geass, 2006) often carry **zero**. There is nothing to "fix" for a title with
no tracks at any source — it's upstream coverage, not a player bug.

## Where the player lives

As of the page-merge (see
[user-features-and-page-architecture.md](user-features-and-page-architecture.md)),
the player is mounted **on the anime page** via `components/WatchPanel.tsx`;
the old `/watch/{slug}-{id}/{ep}` route 308-redirects to `/anime/{id}?ep={ep}`.
