# 08 · Next steps — finishing the initial setup

Where we are and the concrete path to a working standalone self-hosted media
setup on the test box. Acquisition is handled by **Seanime** (the finished
open-source media server); storage/serving follows
[07-storage-design.md](07-storage-design.md).

## Done

- ✅ Box ready: `vast-canada-3` — 9 vCPU, 39 GB RAM, **960 GB free**, Ubuntu 22.04,
  `ffmpeg` + `transmission` + `aria2` + `docker` installed.
- ✅ Storage design validated with real measurements (doc 07): local-FS + HLS,
  remux master / lazy-transcode renditions, GB/episode sizing, LRU eviction.

## Step 1 — Stand up Seanime (acquisition + library)

Seanime is the acquisition engine — it does the search, mapping, download, and
library management. Run it on the box; the `LocalForward 8080` in your SSH config
means you can reach its web UI at `http://localhost:8080` from your laptop.

```bash
# on vast-canada-3
mkdir -p /data/seanime && cd /data/seanime
# grab the latest linux-amd64 release binary from github.com/5rahim/seanime/releases
curl -fsSL -o seanime.tar.gz <latest seanime_linux_amd64 url>
tar xzf seanime.tar.gz && chmod +x seanime
./seanime --datadir /data/seanime    # serves the web UI on :43211 (or configured)
```
Then in the UI: connect AniList, add a torrent-provider extension + a download
client (built-in client or qBittorrent), and **set the library/download dir to
`/data/library`** (on the big disk). Seanime handles mapping/parsing/download —
you don't build any of that.

> Tip: run it under `tmux`/`systemd` so it survives the SSH session. Forward the
> real UI port over SSH if it isn't 8080.

## Step 2 — Pick the storage mode

- ❌ **~~Single-user: let Seanime stream from the library (on-the-fly transcode /
  direct play).~~** **Ruled out** — verified single-user by design (one global
  playback container; whole-transcoder teardown on any unmount; ffmpeg capped at
  ~`NumCPU`; `StreamTypeOptimized` unimplemented). Every concurrent viewer = a
  live transcode. Details: [09-streaming-at-scale.md](09-streaming-at-scale.md).
  **Seanime is the downloader + HLS-prep reference, never the serving origin.**
- ✅ **Served HLS cache (multi-viewer) — the only path.** Apply doc 07: **remux**
  each library file to HLS under `/data/cache/{id}/{ep}/{cat}/`, lazy-build
  720/480, LRU-evict. **Built + measured** in
  [10-pipeline-prototype-measured.md](10-pipeline-prototype-measured.md)
  (`hls_build.py` + nginx; 583× remux, ~1.0–1.9 GB/ep, ~3 ms serve).

## Step 3 — Serve

`nginx`/`Caddy` (or a tiny Python/Go static server) serving `/data/cache` with
HTTP **Range** support; long `Cache-Control` on `.ts`, `no-store` on `.m3u8`.
Verify an HLS player (hls.js) plays `master.m3u8` end-to-end.

## Step 4 — Measure for real

Once a handful of real items are in the library, record from disk:
- **GB/episode** actually observed (vs the ~0.5 GB/1080p estimate),
- transcode realtime factor on this box (≈18× measured),
- segment serve latency.

Those numbers size any future production box (storage TB + bandwidth) — the input
the deferred hosting research needs.

## Scope line

This plan gets you a **standalone working self-hosted media setup on the box**
(Seanime + the storage/serve design). Integrating it into the AniChan backend is
a separate decision and is **not part of this plan** — keep this node standalone
until the storage/transcode numbers are proven.

## Quick reference

| Piece | Tool / doc |
|-------|-----------|
| Acquisition (search/map/download) | **Seanime** (`5rahim/seanime`) |
| Torrent index | AnimeTosho (.xyz) / Nyaa — via Seanime extensions |
| Storage layout + sizing + eviction | [07-storage-design.md](07-storage-design.md) |
| Transcode | `ffmpeg` (remux master; lazy ladder) |
| Serve | nginx/Caddy, HTTP Range, hls.js |
