# 09 · Streaming at scale — the Seanime verdict + the architecture for thousands

The decision that answers *"how do we make streaming available for many, many
users?"* and *"is Seanime applicable for thousands?"*. Sourced from an 8-agent
source-read of Seanime v3.8.7 + a scale/edge research pass, **adversarially
verified against the actual Go source** (core verdict survived; overclaims
corrected below).

## The one-line answer

> **Use Seanime as an offline *downloader* + an HLS-prep *reference*. Never as
> the streaming origin.** Serving thousands is a *static-HLS-at-rest + cache
> mesh* problem, and that half we build ourselves.

## Why Seanime cannot be the origin (verified in source)

Seanime's **acquisition/extraction** code is excellent and reusable. Its
**serving layer is architecturally single-user** — not a tuning problem, a
design problem:

- **One global playback container.** There is a single `currentMediaContainer`
  (`internal/mediastream/playback.go:24,74`); the serving handlers
  (`transcode.go:32`, `directplay.go:65`) resolve the file from that *one*
  global regardless of client. Two viewers on **different** episodes corrupt
  each other — the second `/request` overwrites the global and the first
  viewer's segment fetches start resolving to the wrong file.
- **Global teardown.** Any single player unmount → `ShutdownTranscodeStream` →
  `Destroy()` on **all** sessions (`transcode.go:151-181`, `cassette.go:107-113`);
  each new playback rebuilds the whole transcoder (`repository.go:163-166`). One
  person closing a tab nukes everyone.
- **Transcode-bound throughput.** Non-H.264 sources must transcode; the cassette
  governor caps concurrent ffmpeg at `max(NumCPU,1)` (software) or `max(NumCPU*2,10)`
  (hwaccel) and **blocks** excess on a semaphore (`cassette/governor.go:34-41,50-57`).
  That's single-to-low-double digits per box — not thousands.
- **The one path you'd want is unbuilt.** `StreamTypeOptimized` (pre-transcoded
  HLS at rest) returns `"not implemented"` (`handlers/mediastream.go:111-113`).

**Verify corrections (so we fix the right thing, not a phantom):** Seanime *does*
share on-disk segments across viewers of the **same file+quality** — the cassette
keys `Session`s by file path with a `SegmentTable` (`cassette.go:32,128`,
`segment.go`). The real defects are (a) the cache is **non-durable** (wiped on
teardown and on startup) and (b) serving binds to **one global file**. So the
"every viewer re-encodes from scratch" framing is wrong; the *not-an-origin*
conclusion still holds.

## The architecture that scales (your "many-user shape" — confirmed)

Your shape was right: *light API hands out a playlist URL → player pulls static
HLS segments → an edge/cache layer serves the bulk → origin only handles misses.*
The sharpening: **the hard, expensive half is the offline pipeline that produces
the pre-built HLS.** Two planes:

```
[ INGEST — offline, runs ONCE per episode, O(library) ]   ← on our own box(es)
  AnimeTosho/Nyaa search → release scoring → add batch to transmission
   → analyzer maps files → (season, episode) → deselect unwanted files
   → ffprobe + keyframe list → REMUX (-c:v copy if H.264/AAC) else encode ladder ONCE
   → write IMMUTABLE master.m3u8 + index.m3u8 + *.ts + extracted VTT subs + fonts
   → durable storage on the origin

[ SERVE — online, the request hot path, O(viewers) ]
  player ─GET /episode/X─►  light API (DB lookup only) ─► signed master.m3u8 URL
  player ─GET master/index/*.ts─►  CF proxy (IP shield, forwards complaints)
                                     └► nginx cache mesh (slice + cache_lock)
                                          └─ cold miss only ─► origin-shield
                                                                  └► DMCA-ignored origin
```

The API never touches video bytes; **ffmpeg never runs on the hot path**; origin
egress ≈ *(distinct episodes recently played) × (one cache-fill each)*, not ×
viewers. This matches the verified real-operator topology (one hidden backend,
many cheap cache frontends — the MegaCloud/VidCloud "many frontends, one backend"
model in [01-ecosystem-and-extractors.md](01-ecosystem-and-extractors.md)).

## LIFT from Seanime vs BUILD ourselves

**LIFT** (port into a headless ingest worker — these are pure, viewer-stateless):

*Acquisition / episode-ID (the crown jewels — hardest to rebuild):*
- `internal/torrents/analyzer` — `AnalyzeTorrentFiles` + `GetFileByAniDBEpisode`
  (file paths + AniList media → per-file episode map).
- `internal/library/scanner` — `Matcher` (Sørensen-Dice title scoring,
  `matcher.go:866`), `FileHydrator`, `MediaTreeAnalysis` + `getRelativeEpisodeNumber`
  (`media_tree_analysis.go:125`) — the absolute↔season numbering resolver.
- `internal/torrents/autoselect` — `comparison.go` scoring + `filterCandidates`;
  `torrent/search.go` batch/single fallback; the `hibiketorrent.AnimeProvider`
  interface (`internal/extension/hibike/torrent/types.go:35`) as the provider abstraction.
- `github.com/5rahim/habari` v0.1.12 — drop-in anitomy-style release-name parser.
- `internal/api/anilist/media_tree.go` — sequel/prequel walk for the season chain.
- **Already in-repo (less to build):** the transmission RPC wrapper —
  `TorrentAdd` + `TorrentSet` with `FilesUnwanted`
  (`torrent_clients/torrent_client/repository.go:372,529`) = the deselect-unwanted-files flow.

*One-time HLS generation (per-file, deterministic):*
- `internal/mediastream/videofile/info.go` — `FfprobeGetInfo` + `streamToMimeCodec`
  (RFC6381 codec strings); source of truth for tracks + sub-vs-dub.
- `internal/mediastream/videofile/extract.go` — `ExtractAttachment` ≈ verbatim for
  "extract all subs + **fonts**" (fonts matter: real MKVs ship the ASS fonts —
  18 of them in our test episode).
- `internal/mediastream/transcoder/keyframes.go` — `getKeyframes` (ffprobe
  `packet=pts_time,flags`) so segments split on keyframes.
- `videofile/video_quality.go` `Qualities` ladder + `filestream.go:80` `GetMaster`
  rung logic; the `-c:v copy` H.264 transmux fast path (`quality.go:202`).
  **Change the intent**: encode each rung **ONCE → static files**, not lazily per viewer.

**BUILD ourselves** (everything multi-tenant — none of Seanime's runtime survives fan-out):
- The static-HLS-at-rest **serving** layer (nginx, immutable files, Range, caching).
  *Prototype already built + measured — see [10-pipeline-prototype-measured.md](10-pipeline-prototype-measured.md).*
- The light **playlist API** (DB lookup → signed URL), backed by an
  ingest-populated table `{anilistId → anidbId, absoluteOffset, infohash,
  episode→fileIndex, hlsPath}`.
- The nginx `proxy_cache` + `slice` **edge mesh** + origin-shield, GeoDNS, TLS,
  signed URLs, DDoS handling.

**IGNORE:** the cassette `Session/Pipeline/Governor` runtime, `currentMediaContainer`,
the per-request transcoder reinit, on-unmount global `Destroy`, `torrentstream`
(single-torrent), and `debrid/*` (irrelevant now that on-box torrenting is OK).

**Replace, don't adopt — `animap` (`anime.clap.ing`):** Seanime resolves
AniList→AniDB via the author's **private** metadata service (base64-hidden in
`constants.go:26`, hit per fetch in `animap.go:90`). **Pre-resolve and persist**
AniList→AniDB→absolute-offset in *our* DB at ingest (bulk-import ani.zip /
Fribb anime-lists) so the hot path never depends on a third-party endpoint.

## The serve/edge tier — planning notes (⚠ external, unverified-by-source)

The scale-research agent that was supposed to verify these returned a stub, and
the verifier flagged this whole section as external/legal-risk. **Treat as
planning estimates, not settled facts:**

- **Bandwidth math (arithmetic, sound):** 1080p ≈ 5 Mbps ≈ 2.25 GB/viewer-hour;
  ~160–180 concurrent streams/Gbps. So **1,000 concurrent 1080p ≈ 5 Gbps**;
  "thousands" (3–5k) ≈ **15–25 Gbps**. → can't serve thousands off one cheap VPS;
  need a self-mesh on unmetered offshore ports or a pay-per-TB edge. With caching
  working, the **edge** carries the load and the origin port stays modest.
- **Split (unverified vendor/legal specifics):** origin = DMCA-ignored/offshore
  holding the bytes (leads: BuyVM/Frantech block storage for cheap durable
  storage; offshore unmetered dedis for serving — *verify pricing before spend*);
  edge = "forward-not-delete" cache (Cloudflare free proxy as IP-shield +
  complaint-forwarder; self-built nginx `slice`+`proxy_cache_lock`+
  `background_update` mesh behind one origin-shield). **Do not** treat the
  "rename `.ts`→`.png` to ride CF's free cache" tactic or any vendor price as a
  load-bearing fact — confirm independently, and weigh the legal/ToS risk.
- **Phase-3 mesh is the *primary* scaling lever, not an afterthought.** The
  offload math says the edge mesh (not the origin) carries "thousands", so the
  `slice`+`cache_lock` origin-shield design belongs in the core plan.

## Net

1. Seanime = **ingest worker + HLS-prep reference**, never the origin (verified).
2. Your many-user shape is **correct**; the expensive half is the **offline
   pre-bake**, which is where Seanime's reusable code goes.
3. **Build** the static-HLS-at-rest serving + cache mesh ourselves (prototype
   measured in doc 10).
4. Edge/host/$$ specifics remain the **open gap** — planning estimates only;
   verify before any spend.
