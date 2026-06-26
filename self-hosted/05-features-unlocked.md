# 05 · What owning the bytes unlocks (the *why*)

Self-hosting isn't only resilience — once the file is on our disk it's just an
MKV/MP4, so we can do things **no aggregator can** (they only hold a URL to
someone else's player). These are real product differentiators.

| Feature | How | Notes |
|---------|-----|-------|
| **Scrub-preview thumbnails** | `ffmpeg` frame extraction → sprite sheets + WebVTT thumbnail track | the hover-strip on the seekbar; aggregators can't |
| **Auto skip-intro/outro** | scene-detect / audio-fingerprint the OP/ED → skip markers | replaces hand-entered intro ranges |
| **AI auto-subtitles** | **Whisper** (whisper.cpp / faster-whisper) transcribe + translate | **fixes the "no subs / English-only" gap** we hit earlier — generate subs for episodes that ship without them, in any language |
| **Upscaling** | Real-ESRGAN / Anime4K | old 480p DVD → HD (what Hentai Ocean does) |
| **Transcode ladder** | ffmpeg → HLS 1080/720/480 on the fly | one stored master, multiple qualities |
| **Custom covers / posters** | pick "best frame" per episode | unique art instead of hotlinked AniList images |
| **Visual / scene search, tagging** | CLIP embeddings, character recognition | "find this scene/character"; recommendations from visual features |
| **Clips / auto-trailers** | ffmpeg cut + concat | shareable previews |

The standout: **Whisper auto-subs** directly solves the earlier frustration where
some titles (e.g. Code Geass) had no subtitle tracks at any source — with the
file, we make our own. That alone is a feature no scraper site can match.

> Legal note: the video stays copyrighted — thumbnails, AI-subs, upscales are all
> derivatives, not "cleanly ours." But they sit inside the **same risk envelope as
> hosting the episode** (already accepted), so they add no meaningful new exposure.
