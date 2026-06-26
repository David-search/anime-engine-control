# Going self-hosted: anime acquisition & hosting (research + build plan)

Research + plan for moving AniChan from a **tier-1 aggregator** (today: Miruro →
host HLS, we store nothing) to **self-hosting the video**. Sourced from the
EverythingMoe Discord `index-suggestion` forum (98 topics exported — real
operators describing their stacks), open-source projects (Seanime, Consumet,
Aniways), and web research (a cited deep-research pass is appended separately).

> **Status:** decision made (go self-hosted). Budget: **up to ~$1000/mo**
> (ANIMO-scale runs $150–350). Hard constraint below.

## The constraint that reshapes everything

The content is **unlicensed**, so the actual video **cannot live on mainstream
hosts** — Hetzner, OVH (mostly), AWS, Vercel, **Cloudflare R2/Stream**,
**Backblaze B2**, **Wasabi** all process DMCA and terminate. This is the crux:
self-hosting is not an infra problem, it's a *where-can-the-bytes-physically-sit*
problem. (Verified against the Discord — see Evidence.)

## Ecosystem map (where everyone actually sits)

| Tier | What it stores | Examples (from Discord) | AniChan |
|------|----------------|--------------------------|---------|
| 1 · Embed-only | nothing; iframes a host player | most "new site" submissions | **← today (via Miruro)** |
| 2 · Scraper + own proxy | metadata + scraped m3u8 URLs, served via own CF-Worker/VPS proxy + own player | itachi.tv, AniLight, JustAnime, Anidap | partial (our `watch.py` proxy) |
| 3 · Cache-on-play | downloads segments **on first play**, serves own copy after | ANIMO, AniKuro (starting), PimpAnime | **← Phase 1 target** |
| 4 · Bulk self-host | large pre-built library + host fallback | 2dhive (~19 TB, 70/30), coreflix | Phase 2+ |
| 5 · Release/encode | produces own encodes (AV1, upscale, own subs) | Hentai Ocean | not a goal |

The whole scene leans on the **same few upstream hosts**, and the dominant one is
**MegaPlay = Anikoto = mewstream** (one operator; `noidea` confirms repeatedly).
Other hosts: VidNest/VidWish (redirects to MegaPlay), Videasy, DropFile, AniLink,
animepahe/kwik, AllAnime, ok.ru, blogger.

## 1 · Scraping / extraction (locating the bytes)

- **Backbone:** open-source extractors — **Consumet** and **aniwatch-api**.
  Kyren's dev: *"running my own Consumet instance."* MegaCloud/VidCloud (the
  HiAnime backend) gate streams behind an **encrypted `getSources` endpoint with
  rotating keys** — that's the cat-and-mouse that keeps breaking extractors.
- **Mapping** AniList/MAL ID → a host's episode: `ani.zip`, MALSync,
  Fribb/anime-lists (the same mapping layer Miruro uses).
- **Proxy layer:** **Cloudflare Workers** is the near-universal m3u8/segment
  proxy (hide origin, fix CORS, cache); sites graduate **Vercel/CF-Worker → own
  VPS proxy** as they grow (Vercel's 100 GB cap bites). **Signed/tokenized
  playback URLs** stop other scrapers stealing your streams (Kyren: *"streams
  bypass cache so signed playback URLs aren't shared between users"*).
- AniChan already implements tier-2 of this (`watch.py`: m3u8/seg/vtt proxy with
  Referer/Origin). The `2026 alive/dead state` of each extractor is in the
  appended deep-research.

## 2 · Downloading / acquisition (getting the bytes yourself)

- **Torrents are the real source**, not scraping: nyaa.si, **AnimeTosho** (+ its
  API/feeds), release groups (SubsPlease, Erai-raws). ANIMO: *"from nyaa.si,
  animetosho, most are torrent, and fallback only megaplay scraping."*
- **Torrent STREAMING is the key unlock** — stream pieces **in playback order**
  with no full pre-download. Two flavors:
  - **Raw BitTorrent**: your server joins the swarm. Solves storage, but you
    **download *and seed*** copyrighted content from a datacenter IP — the
    most-monitored piracy activity (swarm honeypots log seeders). Needs a
    **torrent-friendly host**; exposure is *higher* than serving quiet HLS.
    Long-tail/old titles often have **no seeders**.
  - **Debrid (Real-Debrid / Torbox)**: the debrid service already cached the
    torrent and hands you a **direct HTTPS link** — offloads torrenting + legal
    exposure. ~$3–5/mo, magic for *personal* use; **doesn't scale to a public
    site** (ToS forbids resharing, rate-limits, bans shared accounts).
- **Reference implementation: Seanime** (`5rahim/seanime`, Go, open-source
  self-hosted media server). Its `TorrentClient` abstraction swaps
  qBittorrent/Transmission/Torbox/Real-Debrid behind one interface and does the
  sequential-piece serving. It's **single-user** (you watch your own library),
  so not a drop-in backend — but the acquisition/transcode code is the goldmine.
- **Storage math** (per episode): ~150–300 MB @720p, ~400–700 MB @1080p. Storing
  *everything* is the trap — see request-systems + cache-on-play below.

## 3 · Hosting / serving UNLICENSED video (the crux)

What the Discord actually shows (not folklore):

- **B2 / Wasabi / R2 are for images/metadata ONLY.** The only R2 user (Doujiva)
  uses it for *"profile pictures and manga images"* — and even then got pushed
  toward a dedicated host. No anime-video self-hoster stores video on
  B2/Wasabi/R2; they DMCA-terminate video.
- **Cloudflare FORWARDS DMCA — it is *not* an origin shield.** Hentai Ocean:
  *"hide them as hosts by using a reverse proxy. (Cloudflare doesn't count, they
  forward)."* You must hide the real video origin behind a **separate reverse
  proxy**, not rely on CF.
- **Host tolerance (operator-reported):** **Hetzner = strict** (terminates;
  Doujiva fled Hetzner → OVH); **OVH = tolerated-in-practice** (*"somewhat
  DMCA/piracy-ignore… unless IP degradation"*); **BuyVM/Frantech** = the known
  cheap **DMCA-tolerant block-storage** host (Doujiva waiting on stock).
- **Real video storage = dedicated/VDS with big HDDs**, not object storage:
  ANIMO *"5 TB DDR3 → 11 TB, 80 TB bandwidth"*; 2dhive *"19 TB bucket"* (unnamed)
  + *"actively searching for more video hosts/storages for backup."*

### Deep-research findings (verified, June 2026)

A 112-agent cited research pass (29 sources, 25 claims adversarially verified
3-vote, 0 killed) settled the crux:

- **B2 / Wasabi / R2 DMCA-terminate video — confirmed by the providers' own legal
  text.** Backblaze (B2 in scope) + Wasabi both register a DMCA agent + enforce
  repeat-infringer termination; Wasabi's AUP even allows removal *without notice*
  for known-illegal content. **Cloudflare terminated 21,218 R2 accounts for
  streaming piracy in H1 2025** (TorrentFreak/CF transparency report). → cheap
  object storage is **images/metadata only**, never the video. *Resolved.*
- **Cloudflare IS safe as the pass-through proxy/shield** — it *"cannot remove
  content it does not host,"* and for proxied (non-hosted) content it **forwards
  the complaint to the operator + hands the origin IP to the hosting provider**
  rather than taking it down. So **CF in front = fine; the origin must be
  DMCA-ignored**, AND because CF leaks your origin IP to complainants, you still
  hide the real box behind **your own reverse proxy** (matches the Discord's
  *"Cloudflare doesn't count, they forward"*).
- **Datacenter IPs get blocked upstream.** Provider CDNs (DLHD, MegaUp) block all
  datacenter IPs *including Cloudflare Workers' egress* → operators route the
  actual fetch through a **residential-IP proxy**. Real opsec constraint for any
  scrape/proxy layer (and an argument for self-hosting: your *own* bytes don't
  need to dodge upstream IP blocks).
- **Playback gating:** short-lived **RS256-JWT signed URLs** (CF Stream
  `requireSignedURLs`, ≤24h) stop token-less scrapers — anti-theft, orthogonal to
  hosting safety.
- **⚠️ The extraction layer is now legally fragile.** On **2026-03-23 GitHub
  DMCA-blocked the dominant extractor toolchain** — `ghoshRitesh12/aniwatch-api`
  (414+ forks), `aniwatch`, and the `yogesh-hacker/MegacloudKeys` key repo (all
  HTTP 451) — filed by **Remove Your Media LLC for Crunchyroll/VIZ** in a 900+
  repo sweep; HiAnime itself went dark. MegaCloud encrypts stream URLs with
  runtime CryptoJS-AES keys + mutating obfuscation, so extractors break
  constantly *anyway*. **This is the strongest argument for owning your bytes:
  the aggregator/extractor path is one DMCA notice from death.**
- **Acquisition reference:** `sonalys/animeman` (Go) — syncs a MAL/AniList
  "watching" list → Nyaa search → qBittorrent WebUI add. The exact
  watchlist→torrent→download automation, in code.

### Hosting leads (named in sources, NOT adversarially verified)

The research's honest gap: **no concrete DMCA-ignored host name was among the 25
verified claims** — these are *leads* from forum/blog sources to vet, not
verified recommendations:

| Lead | Type | Source quality |
|------|------|----------------|
| **FlokiNET** (Iceland/Romania/Finland) | offshore/no-extradition VPS+dedi | LowEndTalk forum |
| **1984 Hosting** (Iceland) | privacy/offshore | LowEndTalk forum |
| **Njal.la** | privacy domains + VPS | LowEndTalk forum |
| **BuyVM / Frantech** | cheap block-storage slabs, lax | Discord (Doujiva) |
| **OVH** | tolerated-in-practice (not strict) | Discord (Hentai Ocean) |

Taxonomy (dieg.info): "bulletproof" = jurisdictions with **no MLAT/extradition**
(Iceland, Moldova, Seychelles, NL-offshore, RU). **Still unverified:** real $/mo,
unmetered-bandwidth math, per-episode storage sizing, whether a *fleet* of
torrent-seeding nodes is affordable on these. → next research pass.

### Takedown history (what actually kills sites)

ACE/MPA's 2024-2025 crackdown killed **Aniwave, AnimeSuge, HiAnime** (domain +
host pressure); **AnimeHeaven** was nuked when **Crunchyroll's DMCA made its
origin host comply** (catalog replaced with an error string). Lesson: the
**origin host's spine is the single point of failure** — domain/CF you can
rotate, the origin you cannot fake. Choose it like your life depends on it.

Full cited report: `tasks/wo6sjefsq.output` (run wf_eb8349da-25a).

## Revised AniChan self-host plan

- **Phase 0 (today):** tier-1 aggregator via Miruro. **Keep as the fallback**
  forever (cheap, zero storage).
- **Phase 1 — cache-on-play:** tee the segments our proxy already fetches into
  storage on first play; serve our own copy after; LRU-evict cold episodes.
  **Build on the current backend behind a flag — no new spend, low new risk.**
  Ranks a `Source 0 · AniChan (self-hosted, ad-free)` first when cached.
- **Phase 2 (revised) — torrent-stream-on-play + cache:** acquire via
  nyaa/AnimeTosho **torrent streaming** (Seanime-style) instead of bulk
  download; cache the pulled pieces; serve HLS. Runs on a **torrent-friendly
  host**. You only ever store what's watched.
- **Phase 3 — serving infra split:** the load-bearing architecture —
  - **Clean tier** (frontend, catalog/API, metadata, the scraper/proxy backend):
    normal host. **Kamatera fits here** (cheap, configurable, server IP for
    scraping) — but **not** the video tier (5 TB then $10/TB; "unmetered" =
    50 Mbps cap). Cloudflare in front of *this* tier only.
  - **Video tier** (origin storage + serving): **torrent-friendly / DMCA-tolerant
    / offshore**, **hidden behind a reverse proxy** (since CF forwards). This is
    the only legally-hot box; keep it isolated + rotatable.

## Evidence appendix — operator quotes (EverythingMoe Discord)

- **MegaPlay = Anikoto:** `noidea` (repeatedly), incl. *"it's not speculation,
  megaplay is anikoto."*
- **Cloudflare forwards DMCA / hide the host:** `hentaiocean` — *"hide them as
  hosts by using a reverse proxy. (Cloudflare doesn't count, they forward).
  Hetzner has strict no-NSFW/piracy policy, OVH is somewhat DMCA/piracy-ignore."*
- **Hetzner kicks piracy:** `grodondo` (Doujiva) — *"migrated from hetzner to
  ovhcloud… Hetzner wasn't too fond of having +18 content."*  R2 *"for profile
  pictures and manga images."*
- **Cache-on-play = "self-hosted cache":** `wtf.ryan` (ANIMO) — *"those segments
  directly download to my vds so they can be used next time"*; sources
  *"nyaa.si, animetosho… fallback only megaplay scraping."*
- **Bulk hybrid:** `sandiph` (2dhive) — *"70% self hosted, 30% megaplay/anikoto…
  19 TB bucket… falls back to megaplay… searching for more video hosts."*
- **Own embed as a halfway house:** `westye9` (itachi) — *"anilink.cc embed which
  is owned by us, ad-free forever."*
- **Own Consumet + signed URLs:** `luc0131` (Kyren) — *"running my own Consumet
  instance… signed playback URLs aren't shared between users."*
- **CF Worker = bandwidth saver for the VPS:** `light_live` (AniLight) — *"cf
  worker is just for cdn cache hit rate for my vps to avoid high bandwidth."*

## Open questions (deep-research is resolving)

1. Concrete **torrent-friendly / DMCA-ignored host shortlist** + real $/mo +
   unmetered-bandwidth economics at our scale.
2. **Debrid-pool** viability/risk for a public site (Real-Debrid/Torbox).
3. Is **Cloudflare safe as the *proxy/CDN*** in front of pirated video (vs as
   origin), or does fronting it still get you actioned?
4. **2026 alive/dead** state of Consumet / aniwatch-api / gogo / AllAnime and
   what replaced them.
5. **Takedown history** (HiAnime/Zoro/AnimeKai/Aniwave/Gogoanime) — what actually
   killed each, to avoid the same.

See also: [streaming-pipeline-and-player.md](streaming-pipeline-and-player.md)
(current tier-2 implementation) and
[user-features-and-page-architecture.md](user-features-and-page-architecture.md).
