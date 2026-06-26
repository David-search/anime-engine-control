# 07 · Storage design (measured)

How video lays out on disk for a self-hosted media server, with numbers measured
on the test box (9 vCPU / 39 GB RAM / 1 TB disk) using a 10-min Creative-Commons
clip (Big Buck Bunny). Mechanics are container-agnostic — they're identical for
any source file.

## What "storage" actually is here

**The local filesystem on the box** — plain files on the 1 TB disk, served
directly. *Not* object storage (S3/B2/R2): video is latency-sensitive,
range-requested constantly, and object-store egress/op costs and DMCA posture
make it the wrong tool. A big-disk VPS/dedicated serving files off local NVMe/HDD
is the model (this is what ANIMO/2dhive-class self-hosters use).

## On-disk layout (HLS)

HLS = one small text **playlist** + many small **segment** files. Adaptive
(multi-quality) = a master playlist pointing at one sub-playlist per rendition:

```
/data/cache/{animeId}/{ep}/{category}/
├── master.m3u8          # lists the renditions (1080/720/480)
├── v0/                  # rendition 0 (e.g. 1080p)
│   ├── index.m3u8       # lists this rendition's segments
│   ├── seg000.ts ...    # ~6s each
├── v1/  (720p)  index.m3u8 + seg*.ts
├── v2/  (480p)  index.m3u8 + seg*.ts
└── subs/  en.vtt, ...   # extracted subtitle tracks (sidecar)
```

Measured (10-min clip, 6s segments): **92 segments per rendition**, avg segment
**~758 KB** at 360p@800k. A 24-min episode → **~240 segments per rendition**.

## Master: remux, don't re-encode

| Operation | Time (10-min clip, 9 cores) | Output size | When |
|-----------|------------------------------|-------------|------|
| **Remux** (`-c copy` → HLS) | **1 s** (~600× realtime) | ≈ source (lossless repackage) | source already H.264/AAC |
| **Re-encode** ladder (2 renditions) | 33 s (**18× realtime**) | ~1.8× source | need lower renditions / codec convert |

**Strategy:** store the master by **remuxing the source straight to HLS**
(near-instant, lossless, same size). Only **re-encode** when you must — HEVC→H.264
for browser compat, or to generate 720p/480p renditions — and do that **lazily**
(on first request for that quality), then cache the result. Re-encoding everything
up front triples storage and CPU for renditions most viewers never pick.

## GB-per-episode sizing

`size_MB ≈ bitrate_kbps × duration_s ÷ 8 ÷ 1024`. For a **24-min (1440 s)**
episode:

| Quality | Typical bitrate | Per episode | Per 12-ep season | Per 1,000 eps |
|---------|-----------------|-------------|------------------|---------------|
| 480p | ~1.0 Mbps | ~0.18 GB | ~2 GB | ~180 GB |
| 720p | ~2.0 Mbps | ~0.35 GB | ~4 GB | ~350 GB |
| **1080p** | ~3.0 Mbps | **~0.53 GB** | ~6 GB | ~530 GB |
| 1080p (high) | ~4.5 Mbps | ~0.79 GB | ~9 GB | ~790 GB |
| **1080p ladder** (1080+720+480) | — | **~1.0 GB** | ~12 GB | ~1.0 TB |

So on this box's **960 GB free**: ~1,800 single-1080p episodes, or ~900 with a
full ladder. Plenty for a test corpus; production sizing scales linearly from
these.

## Cache + eviction (LRU)

You don't store everything — you cache what's watched and evict the cold tail:

- **Key:** `(animeId, ep, category)` → its directory above.
- **Index:** a small DB/table per cached item: `{key, bytes, created, last_access,
  renditions[]}`. Touch `last_access` on every segment served.
- **Cap:** `CACHE_CAP_GB`. A background **evictor** deletes least-recently-accessed
  *whole episodes* (drop the dir) until under cap. Evict by episode, not segment,
  so a title is all-or-nothing (no half-playable episodes).
- **Warm dedupe:** an in-flight set so two viewers starting the same cold episode
  trigger one fetch, not two.
- **Pin** option: never-evict flag for a curated/always-on set.

## Serving

A static file server is enough — **nginx/Caddy** (or the app) serving
`/data/cache/...` with HTTP **Range** support (HLS players issue range requests
on `.ts`). Set `Cache-Control` long on segments (immutable once written),
`no-store` on the `.m3u8` if it can change. Put it behind a CDN/edge only after
the origin is solid.

## Net storage decisions

1. **Local filesystem**, big disk — not object storage.
2. **Remux the master** (cheap/lossless); **lazy-transcode** lower renditions.
3. **HLS at rest** (segments on disk) so serving is a static file read, not a
   per-view transcode.
4. **LRU evict whole episodes** under a size cap; pin a curated set.
5. Directory key = `{animeId}/{ep}/{category}/` → trivially mappable + cacheable.
