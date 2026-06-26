# 02 · Acquisition — getting the bytes

How AniChan gets episodes once it self-hosts. The mess is solved; here's the
pipeline.

## Source: AnimeTosho (chosen) + Nyaa (fallback)

| | Nyaa | **AnimeTosho (.xyz)** ← chosen |
|---|------|-------------------------------|
| Role | raw firehose | **structured index over Nyaa + others** |
| Data | *"only basic information"* (you parse it) | **per-anime & per-episode, AniDB-mapped, detailed file info** |
| API | RSS only | **JSON API + RSS + DB dump (download the whole index)** |
| Download | torrent only | **torrent + DDL mirror + NZB (Usenet)** |
| Open source | no | **yes** (can self-host the indexer) |

EverythingMoe's verdict matches: Nyaa = *largest, best seeders, basic info only*;
AnimeTosho = *open source, NZB mirror, per-episode view, DB dump*. The "no longer
updated" tag is the **old domain**; **.xyz is the active, upgraded (May 2026)
one**.

**Why AnimeTosho wins for us:** it already did the parsing + AniDB mapping, so we
don't scrape Nyaa HTML. The **DB dump** means no API hammering. The **NZB/Usenet
mirror** is the *no-seeding* download path (pull from a usenet provider ~$10/mo,
**zero P2P upload exposure**) — a real alternative to torrenting.

## Taming the mess (3 layers)

1. **Find** → query AnimeTosho (structured), not raw Nyaa.
2. **Map** → AniList ID → (**Fribb/anime-lists** or **ani.zip**) → **AniDB ID** →
   AnimeTosho query. (Same mapping family Miruro already uses.)
3. **Parse** → filenames via **Anitomy** / **Anitopy** (Py) / **Anitogo** (Go) →
   `{group, title, episode, resolution, codec, checksum}`. The genuinely hard
   part — **absolute-vs-season numbering** (AniDB resets per season; releases use
   absolute "One Piece - 1085") — is handled by **TheXEM** + AniDB + Fribb, not by
   rolling your own.

## Quality + subtitle profile

```
prefer:  1080p · SubsPlease (reliability/seeders) or Erai-raws (multi-sub)
         single-ep for airing · batch+select-file for finished · most seeders
oracle:  SeaDex = curated "best release per anime" (screenshot comparisons)
store:   ONE 1080p master/episode → pre-transcode 720/480 ONCE → cache as static
         HLS (NOT per-viewer; built at ingest or on first request, then reused)
subs:    extract ALL embedded ASS tracks + both audio (sub+dub) from the MKV
         → render ASS in-browser (JASSUB/SubtitlesOctopus) or flatten to WebVTT
note:    dubs are scarce on torrents (new/popular only); sub is abundant
```

## Download granularity — episode vs batch

- **Airing** → per-episode weekly (SubsPlease/Erai-raws). Grab the one episode.
- **Finished/old** → usually only **batch** torrents survive (seeders die on
  per-episode). 
- **It doesn't matter:** with **torrent-streaming** you select and stream **only
  the one episode file** inside a batch — no full-pack download. Seanime's
  `internal/torrents/analyzer` maps torrent files → episode numbers.

## Acquire mechanism — three options

| Mechanism | Storage | Legal exposure | Scale | Use |
|-----------|---------|----------------|-------|-----|
| **Torrent-stream-on-play** (raw BitTorrent) | none until cached | **you seed** from a DC IP (monitored) | medium (seeders vary) | **primary** — on a torrent-friendly host |
| **NZB / Usenet** (AnimeTosho NZB) | downloads to you | **no P2P upload** (you only download) | great | strong alt — needs a usenet provider |
| **Debrid** (Real-Debrid/Torbox) | none (they cache) | offloaded to them | **doesn't scale public** (ToS/limits) | personal only |

## Reference implementations (lift, don't reinvent)

- **Seanime** (`5rahim/seanime`, Go) — the torrent-streaming engine. Key packages:
  `internal/torrents/analyzer` (file→episode), `internal/extension/hibike/torrent`
  (nyaa/AnimeTosho providers), `internal/api/{anizip,anilist,metadata}` (mapping),
  `internal/torrent_clients/{qbittorrent,transmission,builtin_client}`,
  `internal/debrid/{realdebrid,torbox,alldebrid}`,
  `internal/mediastream/{transcoder}` + `internal/mkvparser` (transcode + sub
  extraction). **Single-user** — study it, don't drop it in.
- **animeman** (`sonalys/animeman`, Go) — watchlist (MAL/AniList) → Nyaa search →
  qBittorrent WebUI add. The exact AniList→torrent→download automation, minimal.
