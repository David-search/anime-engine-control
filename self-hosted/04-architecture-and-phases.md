# 04 · AniChan architecture & build phases

The concrete path for *our* codebase. Builds on what exists
([streaming-pipeline-and-player.md](../research/streaming-pipeline-and-player.md):
`watch.py` proxy + hls.js player already do tier-2).

## Principle: split the clean tier from the spicy tier

| Tier | What | Host | Risk |
|------|------|------|------|
| **Clean** | catalog, search, API, metadata, accounts, images, the scraper/proxy backend, frontend | normal host + **Cloudflare shield** | low — DMCA'able without losing the library |
| **Video** | acquire (torrent/NZB) → cache → transcode → serve HLS | **DMCA-ignored / torrent-friendly**, behind own reverse proxy | the only irreplaceable box |

Keep the AniList catalog + the whole current site exactly where it is. Only the
**video origin** moves to the spicy host. This caps blast radius and is how every
durable operator (and itachi's own anilink.cc embed) is structured.

## Phase 1 — cache-on-play (build now, no spend)

Smallest leap from today. Our proxy already fetches HLS segments per the host
referer; **tee them to local storage on first play**, serve our copy after.

- New `cache` module: on a resolved clean HLS source for `(anilistId, ep,
  category)`, background-download the m3u8 + segments + VTT, store under
  `/data/cache/{id}/{ep}/{cat}/`, rewrite a local m3u8 → `/api/stream/...`.
- New serving endpoint `/api/stream/...` serves from disk (no upstream).
- `/api/watch/servers` checks cache first → returns **`Source 0 · AniChan
  (self-hosted, ad-free)`** ranked #1 when cached.
- **LRU eviction** + a storage cap (keep popular, drop cold).
- Build behind a flag on the current backend. Proves the cache-and-serve loop
  **before** paying for the spicy host.

## Phase 2 — torrent-stream-on-play + cache

Replace the acquisition source: instead of re-fetching the host's HLS, **acquire
from AnimeTosho/Nyaa via torrent-streaming** (or NZB), cache, serve. Pipeline:

```
play(ep) → cache hit? serve : 
  AniList→AniDB (Fribb/ani.zip) → AnimeTosho query → score by profile
  → torrent-stream the chosen file (Seanime engine) / or NZB pull
  → extract subs (mkvparser) → transcode to HLS ladder → cache → serve
```
Runs on the **torrent-friendly video host**. Keep Miruro as the fallback source
forever (cheap, zero storage) when acquisition is cold/unseeded.

See [02-acquisition.md](02-acquisition.md) for the parse/map/quality details and
the Seanime/animeman package map.

## Phase 3 — regional cache mesh (scale, build last)

The "P2P" idea, done right as a **server mesh** (not browser-P2P):
- Multiple nodes (US/EU/…). A node near the user serves; on a miss it does
  **HTTP cache-fill from a sibling node** that has the episode (private, fast),
  else torrent-streams from the swarm.
- A small **cache index** (which node has which `(id,ep,cat)`) coordinates it.
- Each node is a torrent-seeding box → **each needs a torrent-friendly host** (the
  mesh *multiplies* the hosting requirement — it doesn't escape it).
- Optional later: browser-WebTorrent to offload bandwidth to viewers (cheap but
  flaky; pushes distribution onto users — decide deliberately).

## What each phase needs from hosting

| Phase | Host need |
|-------|-----------|
| 1 | none new (current backend disk) |
| 2 | **one** torrent-friendly / DMCA-ignored box + reverse-proxy VPS + CF in front |
| 3 | a **fleet** of torrent-friendly boxes (cost question = the open gap) |

## Sequencing rule

**One node first (P1→P2), mesh second (P3).** Don't build the mesh before a
single node proves the acquire→cache→serve loop and the real storage/bandwidth
numbers. The hosting research pass closes the "what box, what cost" gap before
any spend.
