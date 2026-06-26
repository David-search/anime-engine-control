# Self-hosted AniChan — the plan (start here)

Consolidates everything we learned exploring how anime sites really scrape /
download / host, and the **correct path** for moving AniChan from a tier-1
aggregator (today: Miruro) to **self-hosting the video**. Sourced from the
EverythingMoe Discord (98 topics, real operators), open-source projects
(Seanime, AnimeTosho, Consumet, animeman), and a 112-agent cited research pass.

## The decision

- **Goal:** own the bytes — move off the aggregator/extractor path.
- **Budget:** up to ~$1000/mo (comfortable; ANIMO-scale runs $150–350).
- **Why now / why at all:** the aggregator path is **one DMCA notice from death**
  — on **2026-03-23 GitHub nuked the dominant extractor toolchain**
  (`aniwatch-api` + 414 forks + the MegaCloud key repo) for Crunchyroll/VIZ, and
  HiAnime went dark. Self-hosting = resilience.

## The correct path (one screen)

```
SOURCE        AnimeTosho (.xyz) = structured per-episode index (AniDB-mapped,
              DB-dump, NZB/Usenet)  +  Nyaa = raw firehose fallback
ACQUIRE       torrent-stream-on-play (Seanime engine) — pull only the watched
              episode's pieces; NZB/Usenet as the no-seeding alt
PARSE/MAP     AniList ID → (Fribb/ani.zip) → AniDB ID → AnimeTosho query;
              anitomy parses filenames; TheXEM fixes absolute-vs-season numbering;
              SeaDex = "best release" oracle
STORE         one 1080p master/episode → pre-transcode 720/480 ONCE → cache as
              static HLS (built at ingest or first-request, then served to ALL
              viewers as files — never a per-viewer transcode); LRU-evict cold;
              extract ALL subs/audio (sub+dub)
SERVE         SPLIT ARCHITECTURE:
              • clean tier  (catalog/API/frontend/scraper-proxy) → normal host
                + Cloudflare shield in front
              • video tier  (acquire+cache+serve)  → DMCA-ignored / torrent-
                friendly host, hidden behind your OWN reverse proxy
```

## Build phases

1. **Phase 1 — cache-on-play.** Tee the segments our proxy already fetches into
   storage on first play; serve our copy after; LRU-evict. **On the current
   backend, behind a flag — no new spend, low new risk.**
2. **Phase 2 — torrent-stream-on-play + cache.** Acquire via AnimeTosho/Nyaa
   torrent streaming (Seanime as reference); cache pulled pieces. On a
   **torrent-friendly host**.
3. **Phase 3 — regional cache mesh.** Multiple nodes, shared cache index, HTTP
   cache-fill between nodes (your friend's P2P idea — *server* mesh, not
   browser-P2P). Scale optimization, build last.

## Hard constraints (non-negotiable, verified)

- **Unlicensed video cannot sit on mainstream storage.** B2 / Wasabi / R2 / CF
  Stream all DMCA-terminate (Cloudflare killed **21,218 R2 accounts** for
  streaming piracy in H1 2025). Those are for **images/metadata only**.
- **Cloudflare is safe only as the *shield/proxy*** (it can't remove what it
  doesn't host — it forwards the complaint + your origin IP to your host). The
  **origin host is the single point of failure**; pick it like your life depends
  on it, and hide it behind your own reverse proxy.

## The docs

1. [01-ecosystem-and-extractors.md](01-ecosystem-and-extractors.md) — how the
   scene actually works (tiers, MegaPlay/Anikoto, the extractor cat-and-mouse +
   the March 2026 DMCA kill).
2. [02-acquisition.md](02-acquisition.md) — getting the bytes: AnimeTosho/Nyaa,
   parsing/mapping the mess, torrent-streaming vs NZB vs debrid, quality/sub
   profile, Seanime & animeman references.
3. [03-hosting-and-opsec.md](03-hosting-and-opsec.md) — the crux: where unlicensed
   video can live, the host leads, Cloudflare's real role, takedown history,
   survival.
4. [04-architecture-and-phases.md](04-architecture-and-phases.md) — the AniChan
   build: the split architecture, cache-on-play, the mesh, what to build.
5. [05-features-unlocked.md](05-features-unlocked.md) — *why* owning the bytes is
   worth it: sprite thumbnails, AI skip-intro, **Whisper auto-subs**, upscaling.
6. [06-phase-1-plan.md](06-phase-1-plan.md) — the cache-on-play plan + the vast.ai
   test plan.
7. [07-storage-design.md](07-storage-design.md) — **measured** HLS-on-disk layout,
   remux-vs-re-encode, GB/episode sizing, LRU cache/eviction.
8. [08-next-steps.md](08-next-steps.md) — concrete path to a standalone working
   setup (Seanime + storage/serve), measured on the box.
9. [09-streaming-at-scale.md](09-streaming-at-scale.md) — **the scale decision**:
   Seanime = downloader/HLS-prep reference, **never the origin** (verified
   single-user serving); the ingest-vs-serve split; LIFT-vs-BUILD; edge tier.
10. [10-pipeline-prototype-measured.md](10-pipeline-prototype-measured.md) — the
   static-HLS-at-rest pipeline **built + measured** on the box (RTX 4070): real
   acquire→build→serve loop, 583× remux, ~1.0–1.9 GB/ep, ~3 ms serve.
11. [11-ingest-automation.md](11-ingest-automation.md) — the headless library-filler
   (`ingest.py`/`cache_db.py`/`relparser.py`): tiered discovery, eid-anchored
   mapping, batch per-file extraction, completeness gate. **Deployed live** +
   backend/frontend integration (★ AniChan Source 1) + auto-ingest + bug-reviewed.
12. [12-cold-start-and-instant-playback.md](12-cold-start-and-instant-playback.md) —
   **how top sites really do "instant"** (pre-encode + pre-position, NOT
   torrent-stream-on-play); the lever ranking; Webtor.io lifts; the phased plan.
   Phase 1 **pre-cache worker** (`precache.py`) built (paused on the test node —
   belongs on a persistent production host).

13. [13-mapping-rethink.md](13-mapping-rethink.md) —
   **eid-driven, split-cour-proof mapping.** Root-causes why split-cours /
   continuations never cache (199221 Dr. Stone Cour 3 ep1: a *keying bug*, not a
   data gap — ani.zip already hands us eid/season-rel/absolute, we index it wrong).
   Tool survey + recommended architecture (match by AniDB **eid** via AnimeTosho
   `?eid=`, parser-free) + ordered fix plan. Backed by an 8-agent research workflow.

## Open gap (deferred — revisit before production spend)

Concrete **DMCA-ignored + torrent-friendly host** + real **$/mo** + **fleet**
viability is still unverified (leads: FlokiNET, BuyVM/Frantech, Njal.la, 1984,
OVH). Deliberately deferred: we test Phase 1 on **vast.ai** first (zero exposure),
get real GB/episode + egress numbers, *then* pick the production host with data.
The focused hosting research pass can be re-run when we're ready to spend.
