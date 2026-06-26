# 10 · Pipeline prototype — built + measured on the box

The "build the static-HLS-at-rest serving + cache ourselves" half of
[09-streaming-at-scale.md](09-streaming-at-scale.md), **actually built and
measured** on `vast-canada-3` (2026-06-25). Proves the full
**acquire → build HLS-at-rest → serve** loop end-to-end on real content, with
real numbers that size the production fleet.

## The box (better than doc 08 recorded)

`vast-canada-3` (our own vast.ai instance): x86_64, Ubuntu 22.04, **9 vCPU,
39 GB RAM, 960 GB free**, and — **an NVIDIA RTX 4070 (12 GB) with working
`hevc_nvenc`/`h264_nvenc`.** The GPU makes the *one-time* ladder build cheap; it
does **not** change the serving story (still egress-bound → static HLS + edge).

## What was built

- **`hls_build.py`** (on the box at `/data/hls_build.py`) — the doc-07 builder:
  ffprobe → **remux master** (`-c:v copy`) when source is H.264/8-bit, else
  NVENC encode → **NVENC ladder** (720/480) → extract **every** audio track
  (sub+dub) to HLS-AAC → extract **every** subtitle (ASS→WebVTT, italics kept) →
  hand-write `master.m3u8` with `EXT-X-MEDIA` audio+subtitle groups. Emits a JSON
  report (sizes, realtime factors, segment stats).
- **nginx** on `:8080` serving `/data/cache` — Range-aware, `immutable`
  `Cache-Control` on `*.ts`, `no-store` on `*.m3u8`, CORS `*`. (Port matches the
  SSH `LocalForward 8080`, so the package is playable from the laptop.)
- **transmission-daemon** (own config `/data/transmission`, no-auth localhost,
  download → `/data/library`, global seed-ratio 0) as the acquisition client.

## Acquisition — verified (AnimeTosho, not Nyaa)

**Source = AnimeTosho.** The full structured mapping works from the box:
AniList `194317` → AniDB `19381` (via **ani.zip**) → AnimeTosho `aid=19381` →
**75 structured, per-episode, AniDB-mapped releases**, each with a **torrent AND
an NZB** link. AnimeTosho lists each episode across **1080p / 720p / 480p** (21
releases for one episode) in both H.264 and HEVC — so quality + sub choice is
visible at the index, unlike Nyaa's raw firehose.

Pulled real episodes via transmission straight from `storage.animetosho.org`
torrent links (download-only, ratio 0):
- `[SubsPlease] TBATE S2-12 (1080p)` — 1.40 GB, H.264, 1 sub.
- `[Erai-raws] … S2-04 [1080p CR WEB-DL AVC AAC][MultiSub]` — H.264, **9 subs**.
- `[Judas] … S2E04 [1080p HEVC x265 10bit][Multi-Subs]` — HEVC 10-bit, 9 subs.

Airing titles are well-seeded; old/finished fall back to AnimeTosho **NZB/Usenet**.

## Measured — two real sources

### A) Real SubsPlease encode (22.8 min, H.264 8-bit ~8 Mbps, 1 audio jpn, 1 ASS + 18 fonts)

| Step | Mode | Time | Realtime | Output |
|------|------|------|----------|--------|
| 1080p master | **remux `-c:v copy`** | **2.35 s** | **583×** | 1.40 GB (lossless) |
| 720p rendition | h264_nvenc | 104 s | 13.2× | 340 MB |
| 480p rendition | h264_nvenc | 114 s | 12.0× | 169 MB |
| audio (jpn) | aac | 14.8 s | — | 24 MB |
| sub (ASS→VTT) | webvtt | 0.43 s | — | 11 KB |
| **full ladder** | | | | **1.84 GB → ~1.89 GB / 24-min ep** |

### B) Synthesized worst case (3 min, HEVC **10-bit** 1080p, jpn AAC + eng AC3 dub, ASS)

| Step | Mode | Realtime | Output |
|------|------|----------|--------|
| 1080p master | h264_nvenc (HEVC→H.264) | 10.1× | 70 MB |
| 720p / 480p | h264_nvenc | 11.8× / 10.9× | 46 / 23 MB |
| **full ladder** | | | **139 MB → ~1.09 GB / 24-min ep** |

### Serving (nginx, local)

`200` + `Accept-Ranges: bytes` + `immutable` on segments; Range → `206 Partial
Content`; `master.m3u8` → `application/vnd.apple.mpegurl` + `no-store`; **ffmpeg
plays the master end-to-end over HTTP** (real episode + synthesized); segment
fetch **avg 3.3 ms**. Real English subs extracted as genuine dialogue with
`<i>…</i>` styling preserved.

## What the numbers tell us (decision-grade)

1. **Remux vs encode is the whole storage/CPU story.** H.264/8-bit sources
   (SubsPlease/CR — the bulk of airing anime) → **master is a 583× lossless
   remux**, near-zero CPU. Only HEVC/10-bit (some BD encodes) needs the full
   transcode. → **measure the catalog's transmux %**; if most is H.264, the box
   is wildly over-provisioned for ingest.
2. **GB/episode (full ladder) is the storage driver, and it's a knob:**
   - **Remux master (instant, lossless, 8 Mbps): ~1.9 GB/ep.**
   - **Re-encode master to ~3 Mbps (costs ~2–3 min GPU, slight quality loss):
     ~1.0 GB/ep** (matches the synthesized run + doc-07's ~1.0 GB estimate).
   - On 960 GB: ~500 episodes (remux-master ladder) to ~960 (lean-master ladder).
     Production storage scales linearly from here.
3. **The ladder is cheap and one-time.** NVENC builds 720/480 at ~12–13× realtime
   (CPU-decode-bound; a full NVDEC→`scale_cuda`→NVENC pipeline would hit 30×+).
   Built **lazily** (only on first request for that quality) it's off the hot path
   entirely. Either way it's paid **once**, then unlimited viewers read static files.
4. **Serving is trivial per-node** (static file read, ~3 ms). The real serving
   constraint is **egress bandwidth**, not the box — exactly why the edge mesh
   (doc 09 §"serve/edge tier") is the scaling lever, not the origin.

## Qualities + subtitles — measured

- **Qualities:** every package carries a 3-rung ladder (1080p master + 720p +
  480p) in `master.m3u8` as `EXT-X-STREAM-INF` variants; a player switches
  freely. The lower rungs are built **once** (NVENC, static), never per viewer.
- **Subtitles — all of them:** the Erai-raws MultiSub master yielded **9 of 9
  subtitle languages** (`subs_converted: 9, bitmap_skipped: 0`) — eng/por/spa×2/
  ara/fre/ger/ita/rus — each written as **WebVTT** (`EXT-X-MEDIA TYPE=SUBTITLES`,
  for the player) **and** the **original ASS** (kept for a future JASSUB/
  SubtitlesOctopus faithful-styling path). The builder skips bitmap subs
  (PGS/VOBSUB) it can't convert and flags them for OCR.
- Cosmetic: when a group labels every track with a generic source tag (Erai uses
  "CR"), the display NAMEs dedup to "CR (2)…(7)"; the `LANGUAGE` codes (what the
  player's language menu uses) are correct. Polish: fall back to language name.

## Serving throughput — measured (this is the scaling proof)

`wrk` (8 threads, 200 conns, 20 s) hitting random segments across all renditions
over loopback: **5,677 req/s, 14.13 GB/s (~113 Gbit/s) sustained**, avg latency
21.7 ms. → **nginx/CPU/disk is never the serving bottleneck**; static-HLS serving
is purely **NIC-egress-bound**. At ~5 Mbps/1080p stream: **~200 concurrent
viewers per 1 Gbit/s, ~2,000 per 10 Gbit/s** of host egress. Contrast Seanime's
~9–18 live transcodes on the same box — static HLS is **~1000× the concurrency**.

## Transmux % — the cost knob (partially measured)

It's set by which **group** we source: H.264 → instant remux (free), HEVC/10-bit
→ NVENC encode. Observed: SubsPlease/Erai-raws/CR-WEB-DL/ToonsHub = **H.264**
(remux); Judas/ASW/DKB = **HEVC 10-bit** (encode). **Sourcing policy: prefer a
1080p H.264 MultiSub master** (one download = remux video + all subs). Still to
measure at scale: the H.264-vs-HEVC split across a full multi-season catalog.

## Still open (needs the next pass)

- **Full-GPU pipeline** (`-hwaccel cuda -hwaccel_output_format cuda` +
  `scale_cuda`) to push ladder build from ~12× to 30×+ and free the CPU.
- ASS **font** extraction + JASSUB/SubtitlesOctopus for faithful styled subs.
- Catalog-wide **transmux %** (probe a multi-season batch).
- The whole **edge/host/$$** tier — the real open gap (see doc 09).

## Reproduce

```bash
# on vast-canada-3
transmission-daemon -g /data/transmission -w /data/library -T -a 127.0.0.1,::1 -GSR
transmission-remote -gsr 0 && transmission-remote -a "<nyaa .torrent url>"
python3 /data/hls_build.py "<file.mkv>" /data/cache/<id>/<ep>/sub --renditions 1080,720,480
# nginx already serves /data/cache on :8080 (config: /etc/nginx/sites-available/hls)
curl -sI http://localhost:8080/<id>/<ep>/sub/v0/seg000.ts   # 200 + Accept-Ranges
ffmpeg -v error -i http://localhost:8080/<id>/<ep>/sub/master.m3u8 -t 5 -f null -  # plays
```
