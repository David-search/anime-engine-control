# Solutions, Costs, Monetization & Pitfalls

*Deep-dive companion to the architecture explainer. Verified research, 2026-06.*

## Solution Architecture / Product Shape: Every Viable Way to Build a HiAnime-like Anime Streaming Product

There is no single "build an anime site" decision. There is a **spectrum of seven distinct product shapes** that all deliver a HiAnime-style browse → discover → watch experience but differ by orders of magnitude in legal risk, build effort, and operating cost. They sort into three legal buckets:

1. **Clearly illegal piracy** — (A) full pirate clone, (B2) self-hosted scrapers.
2. **Legal-but-fragile gray/aggregation** — (B1) thin proxy of someone else's pirate API, (E)-if-you-scrape-internal-streams.
3. **Fully legal and durable** — (C) BYO-files self-host skin, (D) metadata/tracker, (E)-done-right legal embeds, (F) actual licensing, (G) hybrids of the safe ones.

HiAnime (formerly Zoro → aniwatch) is the canonical **(A)**: scrape source sites, decrypt MegaCloud/RapidCloud `getSources` payloads, proxy `.m3u8` through CORS workers, monetize with adult/popunder ad networks. At its peak it did roughly **244M visits/month (Aug 2025), ~17.5M unique visitors, global rank ~159** — which is exactly why it became the marquee enforcement target. Its open-source ecosystem (`consumet.ts`, `aniwatch` + `aniwatch-api`, `MegacloudKeys`, HLS proxy workers) is what made the pirate path cheap to clone — **until a March 2026 Crunchyroll/VIZ-led takedown removed ~939 repos (incl. forks) and HiAnime itself went dark (~March–June 2026).**

> ### Corrections to first-pass research (read these before trusting any number below)
> - **It was not a settled "DMCA §1201 anti-circumvention sweep."** The 2026-03-23 notice (filed by Remove Your Media LLC for Crunchyroll/VIZ) *asserted* 17 U.S.C. §1201(a)(2), but **GitHub explicitly rejected the §1201 basis** and removed repos only because the notice "contains other valid copyright claim(s)" (per TorrentFreak/Gigazine). The theory that scraper/decrypt code is *per se* illegal circumvention was **not validated**. Takedowns rested on ordinary copyright grounds. Don't repeat the "§1201 sweep" framing as established law.
> - **Consumet was NOT in the original notice.** `consumet/consumet.ts` and `consumet/api.consumet.org` are **not named** in the 2026-03-23 Crunchyroll notice, yet both now return **HTTP 451** — they were taken down in a **later/separate** action. The ~939 figure applies only to the original notice's scope.
> - **AniList catalog size:** "500k+ entries" must not be read as 500k *anime*. Current [docs.anilist.co](https://docs.anilist.co/) says **~20k anime entries and ~100k manga entries**. For an anime product, size for **~20k anime**.
> - **AniList rate limit:** AniList is running **degraded at 30 req/min** (documented as "temporary," long-standing), not the 90/min in its older docs. **Size for 30/min.**
> - **`aniwatch` npm publish date:** v2.27.9 was published **2026-03-14** (per registry.npmjs.org), i.e. *coinciding with* the DMCA wave — not "~May 2026."
> - **Licensing premiums:** the corroborated figure is a **~30–50%+ *simulcast* premium** (exceeding 100% for hot seasonal titles), not a "15–30% *simuldub* premium." The ">$150k/ep" number is the *top* of the $50k–$200k/ep top-tier band, not a floor. (Vitrina is a vendor source — flag accordingly.)
> - **Bunny volume pricing floors lower than cited:** **$0.004/GB (500TB–1PB)** and **$0.002/GB (1PB–2PB)** — effective floor $0.002/GB, not $0.005.

### The seven shapes at a glance

| Shape | What it is | Who pays for video bytes | Legal risk | Build effort | Cost to YOU | Durable in 2026? |
|---|---|---|---|---|---|---|
| **A — Full pirate clone** | Scrape + decrypt + host/proxy unlicensed streams | You (proxy) or source CDN (hotlink) | **Highest** (you are the infringing distributor) | 1–2 wks MVP + *perpetual* firefighting | $5–20/mo hotlink → **$3.5k–$14k/mo at 1M views (proxy)** | No — model actively litigated |
| **B1 — Thin proxy** | Frontend calls *someone else's* pirate API | Their infra | High (downstream infringer) | Days (fork a frontend) | $0–$5/mo | No — dies when upstream dies |
| **B2 — Own scrapers** | Self-host `consumet`/`aniwatch-api` | You (if you also proxy) | **Highest** (same as A) | 1–2 wks + perpetual maintenance | $5–20/mo VPS (+ bandwidth if proxying) | No |
| **C — BYO-files skin** | HiAnime UI over user's own Jellyfin/Plex | **The user** | Low (general-purpose tool) | 2–4 wks (build the skin) | $0–20/mo (metadata/UI only) | **Yes** |
| **D — Tracker/discovery** | AniList-shape lists + "where to watch" deep links | Nobody (no video) | **~Zero** | Days | $0–25/mo | **Yes** |
| **E — Legal-embed aggregator** | Re-skin official free sources (YouTube/FAST) | The platform | Low *if* you respect embed ToS | 1–2 wks | $0–50/mo | **Yes** |
| **F — License catalog** | Become a tiny licensed AVOD/SVOD | You | Low (you own rights) | Months + full streaming stack | **Six figures upfront** | Yes, but not indie-scale |
| **G — Hybrid (D+E+opt-C)** | Safe core + optional power-user backend | User / platform | Low | 1–3 wks | **<$50/mo** | **Yes — recommended** |

### Ranking the dimensions

**By legal risk (highest → lowest):** A ≈ B2 (you operate the scraper + decryptor; the *demonstrated* enforcement target) > B1 (downstream infringer; vanishes with upstream) > E-if-you-scrape-internal-FAST-`m3u8` (ToS/CFAA gray) > **D ≈ E-done-right ≈ C ≈ F (legal).**

**By build effort (lowest → highest):** B1 (days) < D (days) < E (1–2 wks) < A/B2 (1–2 wks to MVP but *perpetual* on-call as keys/HTML rotate) < C (2–4 wks for the Jellyfin-skin UX) ≪ F (months of deals + a full stack).

**By infra cost order-of-magnitude (lowest → highest):** D/E/B1 ≈ $0–50/mo (no video bytes) < C ≈ $5–20/mo to you (user pays storage/bandwidth) < A/B2 hotlink ≈ $5–20/mo until the source blocks you < **A proxy-mode = thousands–tens-of-thousands/mo at scale** ≪ F = six figures upfront + ongoing CDN/DRM.

---

### (A) Full pirate clone — the literal HiAnime model

Run scrapers against source CDNs (MegaCloud/`megacloud.blog`, RapidCloud), decrypt `getSources`, then **either** hotlink the source's `.m3u8` (≈$0, fragile, leaks `referer`, exposes your users to the source's malware ads) **or** proxy every segment through your own infra (reliable, but you pay full video bandwidth).

The pipeline you'd be signing up to maintain forever:

```
frontend → aggregator API (consumet / aniwatch-api)
  → scrape source HTML for episode → server map
  → GET megacloud.blog/embed-2/v2/e-1/getSources?id=...
  → decrypt the encrypted sources string with CryptoJS
     using rotating keys pulled from an external repo (MegacloudKeys)
  → raw .m3u8
  → rewrite playlist + proxy segments through a CORS worker
     (Cloudflare Worker / Flask) to strip referer + add Access-Control headers
```

**Every arrow is a breakpoint the source can change at will.** MegaCloud rotates keys and HTML frequently; you find out in production.

**Proxy-mode bandwidth is the silent budget killer.** A 1080p episode ≈ 0.7–1.4 GB. So **1M episode-views/mo ≈ 700TB–1.4PB**:

| CDN / tier | Rate | 700TB | 1.4PB |
|---|---|---|---|
| Bunny Volume (base) | $0.005/GB | $3,500 | $7,000 |
| Bunny Volume (500TB–1PB) | $0.004/GB | $2,800 | $5,600 |
| Bunny Volume (1PB–2PB) | $0.002/GB | $1,400 | $2,800 |
| Bunny Standard (EU/NA) | $0.01/GB | $7,000 | $14,000 |

([bunny.net/pricing](https://bunny.net/pricing/)). This is precisely why pirate sites hotlink source CDNs and lean on toxic ad networks to survive. **Don't build this in 2026** — see the takedown facts below.

### (B) Thin clone vs own scrapers

Two sub-shapes that look identical to users but differ in *who maintains the scraper*:

- **B1 (thin):** your frontend calls a third-party hosted pirate API (a `consumet`-style host, [ezvidapi](https://ezvidapi.com/alternatives/consumet), a friend's `aniwatch-api` deploy). Lowest effort ($0–5/mo Vercel/CF Pages frontend) — but **consumet's public API was shut down, self-host is now mandatory, and hosted clones get DMCA'd in batches** (414+ `aniwatch-api` forks named at once). Durability is measured in months.
- **B2 (own scrapers):** self-host `consumet`/`aniwatch-api` (Node + Docker, $5–20/mo VPS). Gives control but inherits the **full legal + maintenance load of (A)** — you are now the operator of the scraper/decryptor.

### (C) Self-hosted BYO-files — Jellyfin/Plex skin, *user* supplies files

Ship the HiAnime-style discovery UI on top of [Jellyfin](https://github.com/jellyfin/jellyfin)'s API; **each user runs their own media server and provides their own files** (rips, *arr-stack downloads, public-domain). The infringing copy, storage, and bandwidth all live on the *user's* hardware — you host **zero** video. This is the durable, legitimate analog of HiAnime's UX (à la VLC/Plex as general-purpose tools).

- **Cost to YOU:** a metadata/UI app on a $5–20/mo VPS, or a free static host.
- **Cost to USER:** free Jellyfin (FOSS); a storage box ($400–$1,900 one-time) or $200–500 mini-PC; optional Usenet/indexer ($5–20/mo).
- **Stack:** Jellyfin + Sonarr/Radarr/Bazarr/Jellyseerr (the *arr stack) + AniDB/AniList metadata agents. See [JellyWatch's 2026 automation guide](https://jellywatch.app/blog/jellyfin-full-automation-guide-radarr-sonarr-bazarr-jellyseerr-2026) and [Vallaquenta/jellyfin-arr-stack](https://github.com/Vallaquenta/jellyfin-arr-stack).
- **Legal:** YOU are clean; the user's own copying is their exposure.

### (D) Metadata / tracker / discovery only — AniList-shape, no video

A pure discovery + tracking product (lists, ratings, airing schedule, recommendations) with **no streams**, plus legal "where to watch" deep links from AniList's `ExternalLinkSourceCollection` (Crunchyroll/Netflix/Hulu/VIZ links).

- **Data:** [AniList GraphQL](https://docs.anilist.co/) — free, **no API key**, single endpoint `https://graphql.anilist.co`, **~20k anime / ~100k manga** entries. **Rate limit: assume 30 req/min (degraded), not 90** — so **cache aggressively** (KV/Redis) or you'll throttle at modest traffic.
- **Cost:** $0–25/mo. No video, no scraper, **no DMCA surface.**
- **Legal exposure:** effectively zero (facts/metadata + outbound links). This is what survives DMCA waves untouched.
- **Monetize:** affiliate/referral to Crunchyroll/JustWatch, premium features, non-adult display ads.

### (E) Legal-aggregator — embed only official FREE sources

Re-skin content rights holders give away for free: **Muse Asia** ([youtube channel](https://www.youtube.com/channel/UCGbshtvS9t-8CW11W7TooQg)) & **Ani-One Asia** ([youtube channel](https://www.youtube.com/channel/UC0wNSTMWIL3qaorLx0jie6A)) official simulcasts (embeddable via the **YouTube IFrame Player API**), plus **FAST/AVOD** catalogs (Tubi, Pluto TV's "Anime × HIDIVE" 24/7 channel, Crackle, Plex). The platform serves bytes and pays licensing; you get a HiAnime-like grid of genuinely free, legal anime. Cost $0–50/mo, zero video bandwidth.

**Two traps:** (1) **geo-locks** — Muse/Ani-One are mostly SEA/India (Indonesia, Philippines, India, Vietnam), so coverage is thin for US/EU; (2) **only the official YouTube IFrame embed is clearly safe** — scraping Tubi/Pluto/Plex *internal* `.m3u8` instead of using sanctioned embeds throws you back into ToS/CFAA gray territory. (Vitrina's FAST anime figures — "Pluto 800+ hrs + HIDIVE channel, May 2025"; "Tubi 100M MAU, June 2025" — are platform announcements, likely already superseded: [vitrina.ai](https://vitrina.ai/blog/best-free-anime-streaming-service/).)

### (F) Actually license catalog content

Become a real (even tiny) licensed AVOD/SVOD. The only path to a fully-owned legal catalog — capital-intensive, not an indie weekend project.

| License type | Indicative cost |
|---|---|
| Non-exclusive, single-territory MG | $5,000–$50,000 / title |
| 12-ep mid-tier season, 2–3yr US window | ~$10,000–$25,000 |
| Exclusive top-tier season | $100,000–$500,000+ |
| Major-franchise US-exclusive simulcast | $50k–$200k/ep (>$150k is the *top* of band, not floor) |
| Simulcast premium over delayed | **~30–50%+** (>100% for hot titles) |

(Sources: [Vitrina](https://vitrina.ai/blog/anime-simulcast-deals-structure/) — vendor, flag accordingly; [Anime News Network](https://www.animenewsnetwork.com/feature/2021-08-02/how-much-does-it-cost-to-license-anime-series/.175579).) Plus DRM, CDN, encoding, and ad/sub ops — realistically six figures to launch. An indie's **"F-lite"** is creator/public-domain content (Creator-TV-style AVOD on Plex/Xumo).

### (G) Hybrids — the pragmatic indie sweet spot

- **D + C:** AniList-shaped tracker (the legal product) + optional "connect your Jellyfin" so power users stream their own files in your UI. You host metadata only.
- **E + C:** legal-embed aggregator (Muse/Ani-One/Tubi) for the free catalog + BYO-Jellyfin fallback for everything not legally free.
- **D + E:** tracker with legal "watch free now" embeds where available, deep links elsewhere — 100% legal, genuinely useful, ad/affiliate-monetizable.
- **Anti-pattern:** D/E frontend + (A)/(B) scraper backend "for convenience." This re-imports *all* the legal risk; the 2026 takedown shows it's a when-not-if.

---

### The 2026 takedown — the fact that should drive your decision

- **2026-03-23:** Remove Your Media LLC, for Crunchyroll/VIZ, filed a notice ([github/dmca](https://github.com/github/dmca/blob/master/2026/03/2026-03-23-crunchyroll.md), [raw](https://raw.githubusercontent.com/github/dmca/refs/heads/master/2026/03/2026-03-23-crunchyroll.md)) naming `aniwatch`, `aniwatch-api`, `MegacloudKeys`, `yahyaMomin/hianime-API`, `IrfanKhan66/hianime-mapper`, `ayanrajpoot10/hianime-api`, `itzzzme/anime-api` and more. ~939 repos incl. forks removed ([CBR](https://www.cbr.com/crunchyroll-anime-streaming-hi-anime-github-tool-takedown/), [Collider](https://collider.com/crunchyroll-anti-piracy-github-removes-900-third-party-apps/)). HiAnime went dark.
- **GitHub rejected the §1201 anti-circumvention basis** and removed repos on "other valid copyright claims." So the *settled* posture is ordinary copyright, not validated anti-circumvention.
- **Live status (HTTP probe, June 2026):** `consumet/consumet.ts` → 451; `consumet/api.consumet.org` → 451; org page `github.com/consumet` → 200 (org survives, key repos gone, in a *separate* later action). `ghoshRitesh12` renamed to **`ritesshg`**; `/aniwatch` and `/aniwatch-api` 301-redirect to `ritesshg/...`, both 451. **But the npm artifact survives:** `aniwatch@2.27.9` (published 2026-03-14) is still installable — the package outlived the repo.
- **Domain caveat:** all piracy-mirror claims are volatile; several "hianime" clone domains (`hianime.dk`/`.se`/`.cv`) are flagged malware/phishing. Do not treat any current mirror as stable or safe.

### Key repos (study these, mostly to understand what NOT to operate)

| Repo / API | Status | What it provides |
|---|---|---|
| [ghoshRitesh12/aniwatch](https://github.com/ghoshRitesh12/aniwatch) | 451 (→`ritesshg`); npm survives | Canonical HiAnime scraper (Cheerio/Axios); `src/extractors/megacloud.ts` decrypt logic |
| [ghoshRitesh12/aniwatch-api](https://github.com/ghoshRitesh12/aniwatch-api) | 451 | Self-hostable HTTP API (B2); 414+ forks named in DMCA; Docker on $5–20/mo VPS |
| [consumet/consumet.ts](https://github.com/consumet/consumet.ts) | 451 (separate action) | Multi-source scraper lib (`@consumet/extensions`); maps gogo/Zoro→AniList/Kitsu; public API shut down |
| [yogesh-hacker/MegacloudKeys](https://github.com/yogesh-hacker/MegacloudKeys) | removed | Rotating CryptoJS keys to decrypt MegaCloud `getSources`; without an equivalent, the (A) extractor is dead |
| [Danushka-Madushan/stream-proxy-worker](https://github.com/Danushka-Madushan/stream-proxy-worker) | active | CF Worker HLS/CORS proxy; free 100k req/day but violates CF video-serving terms at scale |
| [AniList GraphQL](https://docs.anilist.co/) | active | Free, no-key metadata backbone for (D)/(G) |
| [Jellyfin](https://github.com/jellyfin/jellyfin) + *arr | active | FOSS media server for (C) BYO-files |

### Technologies by shape

- **Scrapers (A/B2):** Node.js + TypeScript (Cheerio + Axios), CryptoJS for MegaCloud/RapidCloud decryption.
- **Playback (all):** HLS (`.m3u8`) + MPEG-TS; `hls.js` / `video.js` / Plyr / Vidstack players; YouTube IFrame API for (E).
- **Proxying (A/B):** Cloudflare Workers + R2 (zero egress) — **gotcha below**; Bunny.net for real video bandwidth ($0.002–0.06/GB).
- **Metadata (D/G):** AniList GraphQL, consumet REST; Redis/KV caching (mandatory at 30 req/min).
- **Self-host (C):** Docker/Compose, Jellyfin + Sonarr/Radarr/Bazarr/Jellyseerr.
- **Frontend:** Next.js on Vercel / Cloudflare Pages.
- **Monetization:** affiliate + non-adult display (legal path) **vs** ExoClick/TrafficJunky/Adsterra/Clickadu/Monetag (piracy path — see gotcha).

### Gotchas

1. **The pirate path is now actively litigated, not theoretical.** March 2026 removed ~939 repos and HiAnime went dark. Building (A)/(B2) means inheriting a model whose supply chain is collapsing.
2. **GitHub did NOT validate the §1201 theory.** Removals rested on ordinary copyright. Don't lean on "they couldn't prove anti-circumvention" as a defense — they didn't *need* to.
3. **Proxy-mode bandwidth bankrupts you:** ~700TB–1.4PB/mo at 1M views = **$1,400–$14,000/mo** even on cheap Bunny.
4. **Cloudflare forbids serving video/large non-HTML bytes you don't host in CF** (Stream/Images/R2). Old §2.8 moved into [service-specific terms (2023)](https://blog.cloudflare.com/updated-tos/). A free-Workers `m3u8` proxy works at toy scale and gets the account/route banned at real scale — push to Bunny/own VPS. ([Workers pricing](https://developers.cloudflare.com/workers/platform/pricing/), [R2 pricing](https://developers.cloudflare.com/r2/pricing/) — note R2 zero egress, $0.015/GB storage, Class B $0.36/M Standard / $0.90/M Infrequent Access.)
5. **Scrapers are perpetual unpaid on-call:** consumet/aniwatch providers break whenever upstream changes HTML — you find out in production; MegaCloud rotates keys/endpoints frequently.
6. **Thin-clone (B1) durability is illusory:** consumet's public API is gone, self-host mandatory, hosted clones DMCA'd in batches. Your product vanishes when your upstream does.
7. **Legal-embed (E) traps:** Muse/Ani-One are geo-locked (mostly SEA/India), thin for US/EU; only the official YouTube IFrame embed is clearly safe — scraping Tubi/Pluto internal `m3u8` is gray.
8. **Piracy monetization is structurally adult/popunder** because AdSense bans infringing sites. Benchmark CPMs (Kadam-published popunder, *not* BlackHatWorld/AdSpyGlass as first thought): ~**$1.50 Tier-1 / $0.40 Asia / $0.70 Africa / $1.00 CIS**; **adult traffic runs materially higher ($2–$8 on Adsterra)**. That same inventory is the malware vector harming your users.
9. **AniList rate limit is 30 req/min (degraded), not 90.** A (D) tracker MUST cache or it throttles at modest traffic — cheap with KV/Redis, easy to forget.

### Recommendation

**Build D + E + optional-C — the safe hybrid.** It delivers ~80% of the HiAnime browse/discover/watch UX, costs **<$50/mo**, survives DMCA waves, and is monetizable via affiliate + non-adult display ads instead of the toxic popunder/adult networks piracy depends on. Decision framework: (1) *Will you host or proxy unlicensed bytes?* If yes, you are the pirate — stop unless you accept lawsuits + perpetual maintenance + ballooning bandwidth. (2) *Legal, durable, cheap?* Start with **D (tracker)** as the spine. (3) *Want users to actually watch in your UI legally?* Layer **E** (official YouTube/FAST embeds) + optional **C** (BYO Jellyfin). (4) *Have capital and want an owned catalog?* **F-lite** with creator/public-domain content first, then small non-exclusive MGs. **A/B are for nobody who wants to avoid lawsuits in 2026.**

---

## Real Costs to Build and Operate a Free Anime Streaming Site

> **TL;DR for the indie dev:** There is exactly one number that decides whether your site lives or dies, and it is not your server bill. It is **video egress bandwidth**: `(GB watched per user) × (monthly active users) × ($/GB)`. Everything else — scrapers, databases, domains, Cloudflare, encoding — is rounding error at scale. The Zoro → Aniwatch → HiAnime lineage survived as long as it did for one reason: **it made a third party pay the bandwidth.** The moment you proxy video bytes through your own infrastructure, you inherit a six-to-seven-figure monthly bill. This section models five scale tiers and shows you the ~100× cost spread between the cheapest and most expensive egress path.

### The two architectures (and why they differ by 100×)

Everything below flows from one binary design choice:

| | **(A) Embed / Aggregator** | **(B) Self-Host / Proxy** |
|---|---|---|
| What you serve | HTML + JS + (maybe) the `.m3u8` manifest | The `.m3u8` manifest **and** every `.ts` video segment |
| Who pays for video bytes | The upstream host (MegaCloud / RapidCloud / Filemoon) | **You** |
| Your bandwidth cost at 1M MAU | ~$0 (video) | $0 (R2 egress) → ~$144k/mo (bunny) → ~$2.4M/mo (CloudFront) |
| Legal/UX cost | Popups, link rot, extractor arms race | DMCA host termination, encoding pipeline |
| This is what... | zoro.to → aniwatch.to → hianime.to actually did | almost nobody can afford for free anime |

The ZoroTheme front-end family (HiAnime / AniWatch / Kaido / 9AnimeTV) all point at the **same** handful of video hosts — one MegaCloud/RapidCloud/VidCloud backend powers dozens of front-ends. That is architecture (A) in the wild: the front-end is a thin skin; the bandwidth liability lives on someone else's servers.

### ⚠️ Corrections note: the per-episode size anchor (this changes every dollar figure)

First-pass research (and a lot of internet folklore) pegs a 1080p anime episode at **~120 MB streamed**. **This is wrong**, and it is internally contradictory:

- 6.5 Mbps × 24 min ÷ 8 = **~1,170 MB (~1.14 GB)**, not 120 MB.
- A 24-min episode is only ~120 MB at **~0.67 Mbps**, which is **360–480p**, not 1080p.
- Real-world reference: 1080p streaming runs **~50 MB/min ≈ 3 GB/hr** ([Omnistream](https://www.omnistream.live/blog/how-much-data-does-streaming-video-take), [Firsty](https://www.firsty.app/help/general/how-much-data-does-netflix-use)), so a 24-min 1080p episode is **~1.0–1.4 GB streamed**, or **~720 MB** at a lean 4 Mbps.
- Anime *compresses unusually well* (lots of static frames, flat color) — see the [x265 anime encoding guide](https://kokomins.wordpress.com/2019/10/10/anime-encoding-guide-for-x265-and-why-to-never-use-flac/). Typical 1080p torrent **downloads** are ~230–300 MB (the often-cited "~380 MB" is overstated). But **live ABR streaming is *higher* than an offline download** at equal resolution, not lower. The "ABR rarely exceeds 200 MB/episode" claim corresponds to ~480p, not 1080p.

**Use these corrected anchors:**

| Quality | Avg bitrate | Per 24-min episode (streamed) |
|---|---|---|
| 480p | ~1 Mbps | ~180 MB |
| 720p | ~2.5 Mbps | ~450 MB |
| **1080p (H.264)** | **~6 Mbps** | **~1.0–1.1 GB** |
| 1080p (aggressive HEVC/x265, low CRF) | ~2.5–3.5 Mbps | ~450–650 MB |

A moderately engaged user watching **~30 episodes/month at true 1080p ≈ ~30 GB/user/month**, *not* 3.6 GB. **Every downstream figure that was derived from the 120 MB anchor is understated by ~8×.** The tables below use the corrected ~1 GB/episode (~30 GB/user/mo) anchor. The qualitative thesis — a ~100× spread between egress paths — is **unchanged and still correct**; only the absolute dollars move.

> **Opinionated takeaway:** if you genuinely want ~120 MB/episode, you are shipping ~480–540p or hard HEVC, and you should *say so* — don't market it as 1080p. If you're proxying segments, your bandwidth math must assume ~1 GB/ep.

### The egress price table (this is the whole game)

| Provider / path | $/GB egress | Notes & gotchas |
|---|---|---|
| **Cloudflare R2** | **$0.00 (free)** | Pay only storage ($0.015/GB-mo) + **Class B reads $0.36/M**. HLS chunking means *millions* of segment GETs — reads become a real line item. [r2/pricing](https://developers.cloudflare.com/r2/pricing/) |
| **Backblaze B2 + Bandwidth Alliance** | **$0.00** via Cloudflare/bunny/Fastly CDN | Storage $0.006/GB-mo. Free egress **only** through partner CDN routing; direct API GETs beyond 3× stored = $0.01/GB. [b2 pricing](https://www.backblaze.com/cloud-storage/pricing) |
| **bunny.net Volume** | **$0.005/GB** → $0.004 (>500TB) → **$0.002 (>1PB)** | Cheapest *metered* CDN. Trades latency: routes through a small subset of PoPs (reportedly ~10) vs Standard's 119. QoS may force you to Standard. [bunny.net/pricing](https://bunny.net/pricing/) |
| **bunny.net Standard** | $0.01 NA/EU · $0.03 Asia/Oceania · $0.045 S.America · $0.06 ME/Africa | 2–12× Volume cost depending on region. |
| **Hetzner (EU dedicated/cloud)** | **~€1/TB ≈ $0.001/GB** overage | 20–60 TB included per server. "Unmetered" is **fair-use** — saturating 10 Gbps 24/7 with PB-scale video gets you throttled/warned. NOT a free CDN. Prices rose ~33% Apr 2026 and adjusted again [15 Jun 2026](https://docs.hetzner.com/general/infrastructure-and-availability/price-adjustment/). |
| **Contabo / OVH** | "unmetered" fair-use | Same caveat — fine for a scraper, suicidal as a PB-scale video origin. [contabo pricing](https://contabo.com/en/pricing/) |
| **AWS CloudFront** | **$0.085/GB** (US/EU first 10TB) → tiers down to ~$0.02/GB at PB scale; **$0.14–0.17 APAC/India** | **The bankruptcy machine.** Even at the best PB-tier rate it is 10–40× R2/bunny. [cloudfront pricing](https://aws.amazon.com/cloudfront/pricing/) |

**Rule:** never serve video at scale on CloudFront / GCP / Azure. Metered hyperscaler egress is mathematically a bankruptcy path for free video. This is the single most common fatal mistake.

### Cost by scale tier (corrected to ~30 GB/user/month at 1080p)

Two columns: **EMBED** (third party serves video) vs **SELF-HOST/PROXY** (you serve every byte). Egress = `MAU × 30 GB`.

| Tier | Monthly egress (self-host) | **EMBED total/mo** | **SELF-HOST/PROXY total/mo** | $/user (embed) | $/user (self-host) |
|---|---|---|---|---|---|
| **MVP/dev (~1k)** | ~30 TB | **$5–20** (Vercel/Render free + $5 Contabo scraper + $12/yr domain + CF Free + AniList free) | ~same (fits free/cheap tiers) | ~$0.01 | ~$0.01 |
| **10k MAU** | ~300 TB | **$30–60** (1–2 VPS for scraper + *link*-only proxy, CF Free) | R2: ~$300–500 (storage+reads, $0 egress) · bunny Volume ~$1,500 · CloudFront ~$25k 🔴 | ~$0.004 | $0.03–0.05 |
| **100k MAU** | ~3 PB | **$150–350** (2–4 scraper nodes, Redis, CF Pro $20, ~$50 residential proxy, DB $25; you cross AniList's $150 revenue line) | R2: ~$1,000–2,500 · bunny Volume ~$15k · CloudFront ~$250k 🔴 | $0.002–0.0035 | $0.01–0.025 |
| **1M MAU** | ~30 PB | **$1,000–3,000** (CDN for HTML/JS only, 4–8 nodes ~$300–800, CF Business $200, proxies $100–300, DB/cache $100, AniList commercial license) | R2: ~$6–15k (storage ~$600 + **reads ~$5k** + serving) · bunny Volume **~$60–144k** (blends toward $0.002/GB) · Hetzner EU fleet ~$30k · **CloudFront ~$2.4M** 🔴 | $0.001–0.003 | R2 ~$0.006–0.015 · bunny ~$0.06–0.14 · CF ~$2.40 |
| **10M MAU** | ~300 PB | **$3,000–15,000** (scaled scraper fleet, multi-region link proxies, CF Business/Enterprise, heavy proxy spend, big Redis, AniList enterprise) | R2: ~$50–120k (reads dominate) · bunny Volume **~$600k–1.2M** · CloudFront **~$24M** 🔴 | $0.0003–0.0015 | R2 ~$0.005–0.012 · bunny ~$0.06–0.12 |

🔴 = do not do this. (CloudFront figures are worst-case undiscounted at $0.085/GB; PB-scale tier blending pulls it down toward ~$0.02/GB, i.e. ~$600k–$2M at 1M MAU — still bankrupting versus R2.)

> **The punchline:** EMBED stays in the low thousands even at 10M MAU. SELF-HOST is *only* viable on the egress-free path (R2 / B2-via-Bandwidth-Alliance). On any metered CDN, self-hosting free anime at 1M+ MAU is not a business, it's a fundraiser for Amazon.

### The "proxy blow-up" — the trap that converts $0 into six figures

The technical reason piracy sites embed instead of self-host is **CORS + Referer/User-Agent locks**. MegaCloud segments refuse to play from your domain. You have three escalating responses:

1. **iframe-embed the source player** → **$0 video bandwidth.** Highest UX/legal risk (popups, malware-laced ad iframes), zero infra cost.
2. **Proxy only the `.m3u8` manifest**, rewrite it to point at the host's `.ts` URLs, and let the **browser fetch segments directly from the upstream host.** Tiny proxy bandwidth (manifests are KB), host still pays for the GB. **This is the survivor's compromise.**
3. **Proxy the `.ts` segments too** (via [MetaHat/m3u8-streaming-proxy](https://github.com/MetaHat/m3u8-streaming-proxy) or [mediaflow-proxy](https://pypi.org/project/mediaflow-proxy/)) for a clean same-origin player. **Every video byte now transits your infra.** A $5 VPS that handled the scraper cannot move 30 PB/mo — you're forced onto a CDN and you eat full $/GB.

That single choice (option 2 vs option 3) swings 1M-MAU opex from **~$1k/mo to ~$60–144k/mo (bunny) or ~$2.4M/mo (CloudFront)**. Cache hit-rate does **not** save you: anime catalogs are long-tail, edge cache hit-rates are modest, and most bytes still leave the origin.

### Cloudflare's video restriction (a sharper constraint than most realize)

You cannot launder externally-hosted video through Cloudflare's free/Pro/Business CDN. Cloudflare's [updated ToS](https://blog.cloudflare.com/updated-tos/) and [Delivering Videos with Cloudflare](https://developers.cloudflare.com/fundamentals/reference/policies-compliances/delivering-videos-with-cloudflare/) restrict serving video/large non-HTML files **unless the video is hosted on a Cloudflare service** (R2 / Stream / Images). The practical implications:

- **R2-origin video CAN legitimately ride the free CDN** → this is *the* reason R2 is the self-host darling: egress-free storage **and** a compliant free CDN in front of it.
- **Proxied MegaCloud segments routed through Cloudflare's free CDN do not qualify** and risk account action. (Note: an actual account *review/termination* for this is **not explicitly documented** in current ToS — treat that risk as plausible-but-undocumented, not a stated policy.)

### Everything else (the rounding-error tier)

These scale with *users*, not *video*, and stay cheap. Don't optimize them before you've solved bandwidth.

| Component | Tech / repo | Cost | Notes |
|---|---|---|---|
| **Scraper + m3u8 extractor** | [ghoshRitesh12/aniwatch](https://github.com/ghoshRitesh12/aniwatch) (npm), [aniwatch-api](https://github.com/ghoshRitesh12/aniwatch-api), [consumet.ts](https://github.com/consumet/consumet.ts) | Hetzner CPX21 ~€6–8/mo or Contabo $4.95–7/mo (MVP–100k); $50–150/mo fleet at 1M+ | Returns **source links + headers + .vtt subs**, does *not* proxy bytes. ⚠️ `aniwatch-api` repo returns **HTTP 451 (DMCA)**; rely on npm/Docker/forks. Consumet public API is **down** — self-host required. |
| **Object storage (self-host only)** | R2 / B2 / bunny Storage | 20–40 TB catalog: R2 ~$300–600/mo · B2 ~$120–240/mo | ~0.5–0.8 GB/episode all renditions; 20k–50k eps = 15–40 TB. |
| **Encoding (self-host only)** | FFmpeg (H.264/H.265 ABR ladder), or **bunny Stream (FREE encoding)** | FFmpeg on Hetzner: a few hundred $ once, ~$0 steady-state. AWS MediaConvert ~$0.0075–0.015/min = $3.6–7.2k one-time for a 20k-ep library | **Use bunny Stream or FFmpeg; never pay MediaConvert at scale.** |
| **Scraping proxies** | [Webshare](https://aimultiple.com/proxy-pricing) $1–2/GB, IPRoyal ~$1.75/GB, Decodo/Smartproxy $3–8.5/GB, [Bright Data](https://brightdata.com/pricing/proxy-network/residential-proxies) $4.20–12.82/GB; **FlareSolverr** (free, self-hosted headless Chrome) | $2–100/mo | GB consumed is tiny (HTML + small JS). Use cheap datacenter IPs + FlareSolverr first; escalate to residential only when blocked. |
| **Cloudflare (in front of you)** | [Plans](https://www.cloudflare.com/plans/) | Free $0 / Pro $20 / Business $200 / Enterprise ~$3k+; Bot Mgmt add-on ~$30+ | DDoS, SSL, origin hiding (DMCA). Free plan = no WAF/rate-limit. |
| **Database + cache** | Postgres (self-managed Hetzner ~$0–10/mo; Supabase/Neon free→$25), Redis/Upstash free→$10 | $0–50/mo | Redis caches **short-lived extracted m3u8 links** (they expire — re-extract every few min). |
| **Metadata** | [AniList GraphQL](https://docs.anilist.co/guide/terms-of-use) | **Free under $150/mo revenue**; commercial license required above (price **negotiated privately, not public**) | **No bulk hoarding / mirroring** — cache lightly or self-host your own catalog. |
| **Domain(s)** | .com ~$10–15/yr; offshore registrars (Njalla ~€15/yr) for piracy | $15/yr (legit) → $50–300/yr (piracy rotation) | Forced rotation is structural for piracy (zoro→aniwatch→hianime). |

### Monetization reality — why $/user is the verdict

AdSense **bans piracy outright**, forcing you into popunder/native/in-page networks: [Adsterra](https://adsterra.com/blog/tier-1-2-3-traffic-and-tier-country-meaning/), [HilltopAds](https://hilltopads.com/blog/best-cpm-rates-on-popunders-for-publishers-of-hilltopads/), ExoClick, PopAds, Clickadu. Anime piracy traffic skews **Tier-2/3** (India, SEA, LATAM, Africa) where popunder CPMs are roughly **$0.30–$2** (Tier-1 ~$3–8; case-study averages ~$5.35, outliers $0.2–$25 — treat as wide ranges).

At ~30 video/page views per user/month and a blended ~$0.50–1.50 CPM, that's **~$0.015–0.045 ad revenue/user/month.**

| Path | Cost/user/mo (1M MAU) | Ad revenue/user/mo | Verdict |
|---|---|---|---|
| **Embed** | $0.001–0.003 | $0.015–0.045 | ✅ Comfortably profitable (5–40× margin) |
| **Self-host on R2** | ~$0.006–0.015 | $0.015–0.045 | ⚖️ Thin but survivable |
| **Self-host on bunny** | ~$0.06–0.14 | $0.015–0.045 | ❌ Negative (4–9× underwater) |
| **Self-host on CloudFront** | ~$2.40 | $0.015–0.045 | 💀 ~60–160× underwater |

**This table is the entire reason the embed model dominates piracy.** The corrected ~30 GB/user anchor makes self-hosting on *metered* CDNs even more clearly fatal than the old 120 MB number suggested — bunny self-host flips from "thin" to "structurally negative."

### How the survivors minimize egress (the playbook)

1. **iframe-embed the source player** → $0 video bandwidth (highest UX/legal risk).
2. **Proxy only the `.m3u8` manifest**; let the browser fetch `.ts` directly from the host (the practical compromise).
3. If you *must* proxy segments, **use egress-free origins**: Cloudflare R2, or Backblaze B2 through the still-active [Cloudflare Bandwidth Alliance](https://www.backblaze.com/cloud-storage/pricing) (confirmed live in 2026), or bunny Volume at $0.005→$0.002/GB.
4. **Cache hot episodes hard** at the edge — but don't expect it to erase egress (long-tail catalog).
5. **Never** serve video at scale on CloudFront/GCP/Azure.

### The hidden costs no invoice shows you

- **Extractor maintenance is a treadmill.** MegaCloud/RapidCloud rotate encryption keys and obfuscation constantly, breaking `aniwatch`/`consumet` extractors repeatedly. Budget **several hours/week indefinitely** — at $50–100/hr freelance, that's **$1,000–4,000/mo of opportunity cost** even if you do it yourself. This is why those repos churn.
- **DMCA churn is structural, not a risk you can buy down.** Hosts (R2/B2/bunny) terminate on DMCA; registrars seize domains; ad networks and payment processors drop you. The aggregator tooling is *actively disappearing*: `aniwatch-api` is 451'd, Consumet's public API is gone.
- **HiAnime is dead — and this is now confirmed, not speculative.** Earlier research hedged the shutdown as "approximate/unconfirmed (March–June 2026)." That hedge is itself outdated: HiAnime went **offline 13 March 2026** (tied to a 13 March ACE court win / **$18.75M judgment** and a USTR "notorious markets" listing), and the team **officially declared permanent closure on 31 May 2026** after 80 days of inactivity — corroborated by [CBR](https://www.cbr.com/hianime-anime-streaming-site-shuts-down/), [Beebom](https://beebom.com/popular-anime-piracy-site-hianime-officially-shutdown/), and [OtakuKart](https://otakukart.com/no-1-anime-website-hianime-shuts-down-amidst-unprecedented-global-crackdown-on-piracy/). The lineage didn't lose on infra cost; it lost on legal exposure.

### The legit/legal alternative — cheap infra, expensive content

A **legal aggregator** that embeds **official** players (Crunchyroll, official YouTube channels, Bilibili, Muse Asia / AnimeXin embeds) has near-zero bandwidth (the host serves it), **no extractor arms race**, can license AniList for metadata, and can use **mainstream ads + affiliate** revenue. Infra runs **~$20–200/mo even at 100k+ MAU.**

The catch isn't the server bill — it's **content licensing.** Anime sublicensing is gated and very expensive, which is exactly why nobody bootstraps a legal Crunchyroll competitor cheaply. **The only path where self-hosting bandwidth is genuinely affordable is hosting your *own*, public-domain, or properly-licensed content on R2 + Cloudflare** — egress-free storage behind a compliant free CDN.

### Verdict for the indie developer

- **If you're building free anime piracy:** embed (architecture A), proxy *manifests only*, never segments. Your real budget is a $5 scraper VPS, residential proxies, domain rotation, and your own time on the extractor treadmill. Bandwidth is ~$0 — and that's the *only* reason the economics work. Expect the whole thing to be 451'd/seized eventually.
- **If you must self-host:** Cloudflare R2 or Backblaze B2 (via Bandwidth Alliance) are the *only* affordable origins. Model your **Class B read** ops carefully — HLS segment GETs, not egress, become your dominant R2 cost at PB scale. Avoid metered CDNs for video like the plague.
- **If you want something that lasts:** build a *legal* official-embed aggregator. Cheap infra, no arms race — but accept that **content licensing**, not servers, is the wall you'll hit.
- **Model `$/GB` and `GB/user` first. Everything else is noise.** And use the corrected **~1 GB/episode (~30 GB/user/mo)** anchor, not the folklore 120 MB.

---

## Monetization — Revenue Models and Real Economics for Free Anime Streaming

> **Bottom line for an indie dev:** A piracy-grade anime site is a pure ad-arbitrage machine — near-zero marginal cost per stream, but structurally locked out of all high-quality ad demand and every durable payment rail, so it only works at 100M+ monthly visits and dies the moment processors and DMCA-integrated networks de-platform you. The model that actually survives is the *clean* one (licensed/aggregator/news/reviews + legit affiliate + a real subscription), which earns **3–20× the RPM per visitor** but forces you to *earn* traffic instead of riding a leeched library. If you can't realistically hit nine figures of monthly traffic, the piracy economics are not worth the legal exposure — and if you can build the audience, the clean stack out-earns the dirty one per visitor anyway.

### The two business models in one picture

| Dimension | Piracy-grade (zoro→aniwatch→HiAnime class) | Clean / legit (aggregator, news, reviews, simulcast guide) |
|---|---|---|
| Content cost | ~$0 (leeched library, third-party hosts serve video) | Original content + licensing/affiliate relationships |
| Bandwidth/storage | Externalized to MegaCloud/StreamTape/DoodStream-class hosts | You own it (CDN bills) or you don't host streams at all |
| Traffic acquisition | ~Free: SEO + brand recall on a stolen catalog | Hard: must rank/earn on original content |
| Ad demand available | Grey-market pop/push/redirect/VAST only | AdSense/AdX, Ezoic, Mediavine/Raptive (premium) |
| Blended RPM (per 1k pageviews) | **~$0.50–$3** (heavily geo-weighted) | **~$5–$15** (entertainment niche); Mediavine $20–$40 |
| Subscription / donations | "Donation" framing only; no durable card rail | Real Stripe/PayPal freemium tier |
| Affiliate | VPN, dating/adult smartlinks, gaming CPA | Crunchyroll, Amazon Associates (figures/manga), VPN |
| Failure mode | Processor + DMCA de-platforming (existential) | Traffic acquisition is slow (survivable) |
| Marginal cost per stream | ~$0 | Low-to-moderate (your CDN) |

### How the piracy revenue waterfall actually works

A single episode play fires a stacked sequence of independent ad transactions, each billed on a different basis (CPM / CPS / CPA):

1. **Popunder / on-click** — first click anywhere on the player spawns a full-page ad behind the window.
2. **In-player VAST pre-roll** — a video ad before the stream (grey-market fill only).
3. **Banner / native** slots around the player.
4. **Push-permission prompt** — "Allow notifications" to monetize the user *after* they leave.
5. **Affiliate / CPA creatives** — "Watch with VPN", dating/sweepstakes smartlinks.

Two structural facts dominate the P&L:

- **Geo is destiny.** RTB bids vary ~10–50× by country. HiAnime ran ~40% US tier-1 traffic — a minority of pageviews produces the majority of revenue. *Always model by geo, not flat CPM:* a clean site with 100k US pageviews can out-earn a piracy site with 1M tier-3 pageviews.
- **Cost externalization is the whole trick.** The operator pays no licensing (vs. Crunchyroll/Netflix paying tens of millions) and no video bandwidth — third-party hosts store/serve the files. The operator runs only a thin frontend + an `m3u8`/extractor proxy, so margin on ad revenue is extremely high. The structural precondition is open-source scraping tooling like [consumet.ts](https://github.com/consumet/consumet.ts) and the unofficial [aniwatch-api](https://github.com/ghoshRitesh12/aniwatch-api) — both heavily DMCA-pressured around the 2026 shutdown; treat repo availability as unconfirmed and expect to rely on npm artifacts/forks/mirrors.

### Component-by-component: the grey ad stack

#### 1. Popunder / on-click networks — the #1 revenue source

No content review, instant approval, daily/biweekly payouts, anti-adblock baked in. Inventory sold by geo over RTB.

| Network | Tier-1 (US/UK) popunder CPM | Tier-2/3 | Min payout | Payout cadence | Notes / URL |
|---|---|---|---|---|---|
| **PopAds** | ~$4–$6 (mobile Android ~$4.50, desktop ~$3.50) | ~$2–$4, floor ~$0.50 | $5 | **Daily** (PayPal/BTC; wire $500) | Claims ~2B daily views. [affmaven.com/popads-review](https://affmaven.com/popads-review/) · [adspyglass.com](https://www.adspyglass.com/blog/popads-ad-network-review/) |
| **Adsterra** | ~$2–$8 (tech blog hit ~$3.20 Q4'24) | India ~$0.10–$0.50 | $5 Paxum / $100 BTC-PayPal-USDT / **$1000 wire** | Twice monthly (1st & 16th), 2-wk hold | Formats: popunder, Social Bar, Direct Link, native, push. [adsterra.com/blog](https://adsterra.com/blog/popunder-traffic-monetization/) |
| **PropellerAds** | popunder + push CPS | geo-scaled | — | — | ~12B daily impressions, 32k+ advertisers |
| **Clickadu / Galaksion / PopCash / Adcash** | mid-tier | — | PopCash $10 | PayPal/Payoneer/BTC | Clickadu ~5B daily impressions. [hilltopads.com/blog](https://hilltopads.com/blog/top-10-pop-ad-networks-of-2024/) |

**Practical blended popunder eCPM** for a mixed-geo anime site (~40% US): **~$1.0–$2.5**, with effectively ~100% fill (remnant/house fallback). Self-reported PopAds earnings on a 50k-visit tech blog: ~$847/mo — a useful sanity anchor for how low this is.

#### 2. Push-notification subscriptions — the "lifetime annuity"

The visitor opts into notifications; the network then pays per subscriber (CPS) and/or per push impression for *weeks after they leave*. Recurring and ad-block-resistant — this is the layer that converts a one-time visit into ongoing revenue.

- Push CPM: tier-1 ~$1–$2+, tier-2/3 ~$0.10–$0.50; PropellerAds floor ~$0.01.
- Worked example (industry): 300k subscribers × $0.10 CPM × 1 push/day ≈ **$30/day ≈ $900/mo** from already-captured users. CPS is a flat per-opt-in fee (cents to ~$0.30+ tier-1). See [izooto.com push guide](https://izooto.com/blog/push-advertising-explained).

#### 3. Direct link / interstitial / Social Bar

High-CPM redirect placements on play/episode-change, plus the "Social Bar" (a fake-notification widget). Adsterra reports Social Bar mobile CTR ~2× traditional banners; interstitial/redirect CPMs track popunder rates (tier-1 ~$2–$8). **Categorically banned on any AdSense-monetized clean site** — this is a piracy-only layer.

#### 4. In-player video pre-roll (VAST) & SSAI

The highest-CPM format in the *legit* world — and the one piracy can least access.

| Inventory | CPM | Available to piracy? |
|---|---|---|
| Premium non-skippable pre-roll | ~$14 | **No** |
| Premium skippable pre-roll | ~$12 | **No** |
| CTV | $20–$60 | **No** |
| Grey-market VAST (ExoClick / HilltopAds video / Adsterra video) | ~$1–$5, low fill, frequent passback/blank | Yes |

Premium video demand refuses piracy outright (see [richads.com pre-roll guide](https://richads.com/blog/pre-roll-ads-guide/)). **SSAI** (server-side ad insertion) would beat ad-blockers by stitching ads into the manifest — but piracy operators rarely run real SSAI because *they don't own the origin*; the third-party host does. SSAI is a tool for the clean model, not the dirty one.

#### 5. Affiliate & CPA — often the highest-margin layer

The anime audience genuinely wants VPNs and merch, and CPA networks don't police publisher legality.

| Offer | Payout | Source |
|---|---|---|
| **NordVPN** | up to 100% of a 1-mo plan + **30% recurring** on renewals (40% on 1/2-yr) | [wecantrack.com/nordvpn](https://wecantrack.com/programs/nordvpn-affiliate-program/) |
| **ExpressVPN** | fixed ~$13 (1mo) / $22 (6mo) / $36 (12mo) per paid signup; $100 min payout | [theaffiliatemonkey.com](https://theaffiliatemonkey.com/best-vpn-affiliate-programs-2024/) |
| **CrakRevenue** (adult/dating smartlink) | Victoria Milan $75 PPS, Ashley Madison up to $70 PPS, AdultFriendFinder $60 PPS; 300+ offers, >$10M paid via smartlinks | [mobidea.com/crakrevenue-review](https://www.mobidea.com/academy/crakrevenue-review/) |
| **Clean affiliate** | Crunchyroll affiliate; Amazon Associates figures/manga (~3–4% category); merch — lower payout, advertiser-safe | — |

The recurring VPN commissions and CPA renewals are what partly offset the brutally low per-view eCPM and ad-blocker leakage on a piracy site.

#### 6–9. The thin tail: subscription, donations, mining, data

- **Premium "no-ads" tier** (~$2–$5/mo, framed as "donation for servers"). Freemium-to-paid medians: ~2–5% (good 3–5%, excellent 6–8%); ad-supported→paid streaming often 2–3% ([adapty.io benchmarks](https://adapty.io/blog/trial-conversion-rates-for-in-app-subscriptions/)). **This layer kills piracy sites** — it needs a card processor that drops you for infringement.
- **Donations / Patreon / crypto tips** — small absolute dollars; Visa/MC pressure has de-platformed creators (esp. adult-adjacent), so BTC/Monero is the de-facto fallback. See [the Visa/Mastercard de-platforming pattern](https://automaton-media.com/en/news/another-japanese-content-creators-platform-loses-visa-mastercard-support/).
- **Cryptojacking** — *dead economics.* Coinhive (~62% of in-browser miners, ~$250k/mo at peak, first big adopter The Pirate Bay) [shut down 8 Mar 2019](https://blog.avast.com/coinhive-shuts-down) after XMR fell ~85%. Yields cents and instant AV/reputation flags today. **Do not consider it.**
- **Data monetization** (cookies/trackers sold to brokers) — quietly present on piracy sites, unquantified, and legally radioactive under GDPR/CCPA for a clean operator.

### The clean stack — the path a developer can actually use

The *only* mainstream high-quality demand, available exclusively to advertiser-safe sites:

| Network | Entertainment-niche RPM | Threshold / notes |
|---|---|---|
| **Google AdSense** | ~$3–$10 | Bans infringing sites outright |
| **Ezoic** | similar-to-better (header bidding) | Low entry barrier |
| **Mediavine** | **~$20–$40** | 50k+ monthly sessions + original content; "Journey" tier at 1,000+ sessions, 70% rev share |
| **Raptive** (ex-AdThrive) | premium | Dropped to 25k monthly PV (Oct 2025), but needs ≥50% tier-1 for sub-100k sites |

Overall entertainment-niche band: **~$5–$15 RPM** — multiples of piracy-grade blended RPM despite lower raw traffic. Comparison detail: [adsense vs Mediavine/Ezoic](https://eastondev.com/blog/en/posts/media/20260110-adsense-alternatives-comparison/).

### Revenue at scale (MODELED — preserve the hedges)

| Monthly pageviews | Piracy-grade (ads + CPA) | Clean/legit |
|---|---|---|
| 100k | **$50–$250/mo** | **$500–$1,500/mo** (RPM $5–15) |
| 1M | **$500–$2,500/mo** | **$5k–$15k/mo** ads (+ subscription, see caveat) |
| 10M | **$5k–$25k/mo** | **$50k–$150k/mo** ads |

These are **modeled** ranges, not booked revenue. The clean RPM runs **~3–20× piracy RPM**.

### The HiAnime case-study numbers (treat as estimates, not financials)

- **Traffic:** ~331–364M monthly visits at the Oct 2024 peak; SimilarWeb global rank ~#120 (confirmed). US share **~40%** is *independently confirmed* by [TorrentFreak](https://en.wikipedia.org/wiki/HiAnime). India is confirmed only as the **#2 country** — the widely-quoted "~25%" is **unverified** (Similarweb/Semrush specifics are paywalled).
- **Revenue:** ~**$400k/month from ads** is a *media estimate* from a single niche outlet ([animexnews.com](https://animexnews.com/how-anime-piracy-websites-make-money-despite-being-ineligible-for-prominent-ad-services/)), **not disclosed financials.** Its math: 331M × 50% (see-an-ad assumption) × $0.004 per monetized view (a ~$4 CPM, matching PopAds US tier-1) ≈ ~$662k — so $400k is a *conservative restatement*, and it's an upper-bound model because the ~50%-see-an-ad assumption ignores heavy ad-block leakage in this audience.
- **Shutdown:** ~March–June 2026 after ACE/USTR pressure (USTR "notorious markets" listing early March 2026); 9anime/AnimeKai went dark and a ~$18.75M ACE judgment landed in the same window. Treat exact dates as *reported*, per [CBR](https://www.cbr.com/hianime-america-government-notorious-market-list-2025/) / Wikipedia, not primary.

### Corrections to first-pass research

- **The $400k estimate's eCPM is *not* unspecified.** First-pass said the network mix *and* eCPM were unknown — wrong. AnimeXNews explicitly assumes **$0.004/monetized view (≈$4 CPM)**. Only the *network mix* is unstated. (And their own formula yields ~$662k, making $400k conservative.)
- **PopAds was *not* confirmed as HiAnime's primary network.** AnimeXNews names PopAds only as a *category example* ("such as PopAds"), not HiAnime's specific vendor. Soften any claim to: *PopAds cited as a class example; HiAnime's actual networks are unverified.*
- **"Subscription dwarfs ads" is illustrative only.** The seductive "1M MAU × 3% × $4/mo = ~$120k/mo" figure conflates **pageviews with paid-eligible MAU** — 1M monthly pageviews is *not* 1M MAU, overstating the conversion base by a large factor. Downgrade this conclusion to illustrative; it does not hold under realistic MAU.
- **The MegaCloud "host pays uploader $10–$25 / 10k views" model is the wrong mental model for this case study.** That figure references *defunct* revenue-share hosts (Openload/Streamango). **MegaCloud is best understood as a captive/embedded player** in the zoro→aniwatch→HiAnime lineage (scraped by consumet / aniwatch-api), *not* an independent revenue-share file host. For a captive host, the video-delivery margin accrues to the **operator**, not a third-party uploader — so the Openload analogy is structurally misleading here even though the number is accurately cited.
- **The India "~25%" traffic share is unverified** — confirmed only as #2 country.
- **Ad-network thresholds shifted in late 2025 / early 2026**, which *strengthens* the clean-site upside but changes the access path: Raptive dropped to 25k PV (Oct 2025, with a ≥50% tier-1 requirement sub-100k); Mediavine added a **$5,000/yr-ad-revenue alternative path** (effective Jan 15, 2026) and runs "Journey" at 1,000+ sessions. So a 100k-PV clean anime site *can* plausibly reach premium networks — but it's not the naive "just sign up for Mediavine."

### Gotchas (the ones that decide whether you build this)

- **AdSense and virtually all premium demand refuse piracy by policy.** A valid DMCA notice strips ads from the page and *permanently* blocks future AdSense on it. Piracy sites are hard-capped at $0.50–$3 grey-market eCPM. See [AdSense copyright policy](https://support.google.com/adspolicy/answer/6018015?hl=en) and [Google's DMCA ad removal](https://fightingpiracy.withgoogle.com/google-policies-by-product/).
- **Ad-block leakage is severe in this exact audience.** Anime/tech-savvy users run uBlock/Brave at high rates, so a large share of "pageviews" never render an ad. Every revenue estimate assuming ~50% see ads is an **upper bound**, not booked revenue.
- **Per-view payout is brutal:** ~$0.004 per monetized view. The business *only* works at 100M+ monthly visits; at small scale, piracy monetization is not worth the legal exposure — full stop.
- **Payment-processor bans kill the subscription/donation layer.** Visa/MC/PayPal drop infringing and adjacent-NSFW merchants (2021 Mastercard adult-merchant rules tightened this further). A piracy "premium tier" has *no durable card rail* — hence "donations" and crypto.
- **Grey networks have hidden frictions:** shaving (under-counted impressions), high min-payout tiers (Adsterra $100 BTC / $1000 wire), 2-week holds, and terminations for "invalid traffic." Payouts are real but lossy and unstable.
- **Pop/push/redirect creatives carry malware/scam ads** (fake-update, dating, sweepstakes) → Google Safe Browsing + ad-blocker-list flags → suppressed fill and dead reputation. A self-reinforcing downward spiral.
- **Legit RPMs require *earned* traffic + original content.** You cannot reskin a leeched library and expect $20–$40 RPM. The clean model trades higher per-visitor revenue for much harder traffic acquisition — that is the central tradeoff of this entire decision.

> **Evidentiary caveat (load-bearing):** The strongest single source under the whole monetization narrative — the $400k estimate, the PopAds attribution, the host-payout figure, the "grey-market stack" framing — is **one niche secondary article (animexnews.com)** doing back-of-envelope math. Mainstream outlets (TorrentFreak, CBR) corroborate only the **traffic and shutdown facts, never the revenue**. The macro industry-loss figures (~2.3 trillion yen / ~$15.1B; a separate METI survey at ~5.7 trillion yen / ~$38B) are industry-advocacy estimates, not hard financials. Build your spreadsheet on the *structure* of these models, not on any single dollar figure.

---

## Pitfalls & Failure Modes: The Complete Map

> **TL;DR for an indie dev:** A free anime aggregator/piracy site is not a product you "build and own" — it is a continuous loss-mitigation exercise across **six** simultaneous failure domains (technical, legal, operational, financial, security/reputation, business). Every one of them has a near-fatal pitfall, and there is **no single design that survives all six** *except* (a) a fully legal metadata/link-out aggregator using licensed APIs, or (b) self-hosting your own legally-acquired library. Everything in between is a treadmill that ends in a takedown, a deplatforming cascade, or — if you take money — a felony. The rest of this section is the map of exactly where it breaks.

---

### 0. The shape of the problem

The reason a "zoro clone" is uniquely miserable to operate is **structural dependency on an adversarial upstream**. You don't have the video. You scrape it from another pirate (MegaCloud/RapidCloud), who *deliberately* breaks you to protect themselves, while rightsholders *deliberately* break you to kill the category, while every neutral vendor (CDN, host, registrar, ad network, payment processor) can drop you the moment they get a notice. You are sandwiched between three groups who all want you dead and one (your users) you end up infecting with malware because the clean money rails won't touch you.

| Failure domain | The core pitfall | Can you mitigate? |
|---|---|---|
| **Technical** | Extractor/decryptor rots every key/domain rotation; all clones break at once | Only via a perpetual re-RE treadmill — never permanent |
| **Legal** | PLSA makes for-profit streaming a **felony** (up to 10 yrs); real people are in prison | No technical fix — only "don't operate it for profit / don't host streams" |
| **Operational** | Every vendor (CDN/host/registrar/ad/payments) can cut you; coordinated takedowns | Offshore + domain-hopping only *delays* it |
| **Financial** | Proxying video for CORS routes all bandwidth through you; egress > ad revenue | Free-egress storage (R2/Bunny) or stop proxying (accept breakage) |
| **Security/Reputation** | Locked out of clean ads → malvertising → you infect your own users | None that preserves revenue |
| **Business** | "Pirate Update" demotion + AdSense bans + no moat + **no legal exit** | None — the asset is structurally unsellable |

---

### 1. TECHNICAL — the "breakage treadmill"

#### 1.1 The extractor/decryptor rot (the #1 maintenance killer)

This is the single most important thing an indie dev underestimates. Pirate video hosts like **MegaCloud** (which USTR names as the backend feeding 260+ pirate sites with 46,000+ movies / 16,000+ TV series) ship obfuscated JavaScript that derives an **AES key**, encrypts the `m3u8` URL, and then *rotates the key, re-obfuscates the JS, or moves the embed domain on a whim*. The instant they do, **every downstream clone black-screens simultaneously** — your site, the consumet sites, the aniwatch sites, all at once, with zero warning.

Concrete, dated evidence this is real and not theoretical:

- **`megacloud.blog` expired → streams moved to `megacloud.tv`.** Every site with a hardcoded `.blog` embed URL broke at the same moment. The community firefight is documented in [ghoshRitesh12/aniwatch issue #17](https://github.com/ghoshRitesh12/aniwatch/issues/17) and patched ad-hoc by [RAELIE1/MegaCloudFix](https://github.com/RAELIE1/MegaCloudFix) (a `.blog`→`.tv` rewrite + Tampermonkey redirect scripts).
- The cleanest single artifact proving "key rotation kills extractors": [**Eggwite/megacloud-key-extractor**](https://github.com/Eggwite/megacloud-key-extractor) — an AST/pattern-matching tool to pull the AES key from the obfuscated JS — is now **explicitly titled "NO LONGER FUNCTIONAL"** in its own repo, after a rotation defeated it.
- `aniwatch-api` degraded to pulling keys from a crowd-sourced feed (`yogesh-hacker/MegacloudKeys`) and then to surfacing user-facing "**The Mega Link May Not Work, go with Alternative**" messages — i.e., the maintainer gave up on a reliable fix and pushed the failure to the user.
- The release history of [consumet/consumet.ts](https://github.com/consumet/consumet.ts) is, in practice, a changelog of "fixed broken extractor after upstream rotation." That *is* the treadmill, version-controlled.

**Why there is no permanent fix:** the upstream is adversarial *and* unpaid. You will re-reverse-engineer the key derivation, ship a patch, and repeat — indefinitely — until you burn out, at which point the repo gets archived or stamped NO LONGER FUNCTIONAL. There is no SLA, no contract, no roadmap you control. This is the dependency that makes a zoro/hianime clone fundamentally **un-ownable**.

#### 1.2 Cloudflare anti-bot / Turnstile kills HTTP-only scrapers

Before you can even *get* the obfuscated JS, you have to fetch the upstream page — which is usually behind **Cloudflare Turnstile / Bot Management**. Turnstile runs invisible JS fingerprint challenges; a plain `requests`/`axios`/`httpx` client fails instantly because it can't produce a token. Detection got *"significantly more aggressive"* across 2024–2025 ([Scrapfly: How to Bypass Cloudflare in 2026](https://scrapfly.io/blog/posts/how-to-bypass-cloudflare-anti-scraping)).

Your options, in ascending cost/fragility:

| Approach | Tooling | Reality |
|---|---|---|
| HTTP client | `requests`, `axios`, `httpx` | **Fails immediately** — no JS, no token |
| Headless real browser + stealth | [Camoufox](https://github.com/daijro/camoufox), SeleniumBase UC mode, [playwright-stealth](https://github.com/AtuboDad/playwright_stealth) | Works for a while; heavy (RAM/CPU per session); breaks on CF updates |
| Open-source solvers | [FlareSolverr](https://github.com/FlareSolverr/FlareSolverr), [Byparr](https://github.com/ThePhaseless/Byparr) (Camoufox-based) | Strongest free options; still cat-and-mouse, frequently stale |
| Paid "Web Unlocker" | Bright Data Web Unlocker, Scrapfly, ZenRows | Most reliable vs Cloudflare/DataDome; **highest cost**, per-request billing |

Every tier adds latency and cost, and every Cloudflare update re-breaks the free tiers. There is no durable free fix.

#### 1.3 The `m3u8`/HLS player layer: CORS, codec, mixed-content, segment failures

Even with a working stream URL, the browser blocks playback. HLS is chatty — manifest → media playlist → segments → encryption keys → subtitle tracks — and **each request can fail CORS independently**. `hls.js` uses XHR, so the browser enforces cross-origin at the network layer (see [react-player #1699](https://github.com/cookpete/react-player/issues/1699) for the canonical CORS-on-`.m3u8` complaint). Add **mixed-content blocking** when the upstream stream is HTTP and your site is HTTPS, and the only fix is to run an `m3u8` proxy that rewrites every segment URL through your server and injects CORS headers — e.g. [itzzzme/m3u8proxy](https://github.com/itzzzme/m3u8proxy) or [MetaHat/m3u8-streaming-proxy](https://github.com/MetaHat/m3u8-streaming-proxy).

That fix **creates the next, worse problem.**

---

### 2. FINANCIAL — proxy bandwidth runaway (the technical fix that bankrupts you)

The moment you proxy `m3u8` segments to beat CORS/hotlink protection, **every byte of video transits your server/CDN instead of the upstream's.** A single 1080p anime episode is roughly **0.7–1.5 GB**. At any real scale, bandwidth — not features — becomes the dominant cost line, and on an egress-billed CDN it can exceed your entire ad revenue.

The provider spread is enormous and is the single most consequential infra decision you'll make:

| Provider | Billing model | Effective price | 50 TB/mo (egress) | Notes |
|---|---|---|---|---|
| **AWS CloudFront** | per-GB egress | ~**$0.085/GB** | ~**$4,350** | Worst case for raw proxying |
| **Fastly** | per-GB egress | ~$0.08–0.12/GB | ~$4,000–6,000 | Premium, similar trap |
| **Bunny CDN** | per-GB egress | ~**$0.005/GB** (EU/NA) | ~**$250** | ~17x cheaper than CloudFront |
| **Bunny Stream** | per **delivered minute** | ~$0.005/min | n/a (per-min) | Don't conflate with Bunny CDN's per-GB |
| **Cloudflare R2** | storage + **$0 egress** | $0.015/GB-mo storage, **$0 egress** | **~$0 egress** | Free-egress is the cheat code |
| **Cloudflare Stream** | per delivered minute | ~$0.01/min | n/a | Will TOS-ban pirated content anyway |

> **Corrections note (re-verify before relying):** these are 2025–2026 **list prices** and move frequently. Two specific clarifications vs first-pass research: (1) **"Bunny ~$0.005/min" is Bunny *Stream* (per delivered video-minute); Bunny *CDN* is ~$0.005/GB.** Don't compare per-minute against CloudFront's per-GB. (2) The headline egress spread between providers exceeds **17–18x** at scale, which is why egress (~80% of media cost) — not compute — dictates the economics.

The brutal tension: free-egress storage (**R2**, Bunny) makes proxying survivable, but the *legitimate* free-egress providers (Cloudflare especially) will terminate you for piracy under their repeat-infringer policy. The only no-bandwidth alternative is to **302-redirect to the upstream and not proxy at all** — which reintroduces the CORS/hotlink breakage you were trying to fix. There is no clean answer; this is a real, permanent trade-off.

#### 2.1 Scraping bandwidth costs (the other meter running)

Your scraper boxes get datacenter-IP-banned by strict WAFs fast, pushing you to residential proxies that bleed money:

| Proxy type (Bright Data) | Price | Survives strict anti-bot? |
|---|---|---|
| Datacenter | **$0.066–0.09/GB** | No — blocked easily |
| Residential (PAYG) | **$5.88–8.40/GB** (~$3/GB committed) | Yes — hardest to detect |
| Mobile | ~**$14.4/GB** | Yes — most expensive |

Source: [Bright Data residential pricing](https://brightdata.com/pricing/proxy-network/residential-proxies). Residential is the only tier that reliably survives, and it's 60–120x the datacenter price.

---

### 3. TECHNICAL (the reason you're parasitic) — Widevine L1 you cannot bypass

This is *why* the whole ecosystem scrapes other pirates instead of ripping Crunchyroll/Netflix directly, and therefore *why* it inherits MegaCloud's fragility. HD content is protected by **Widevine L1**, where decryption happens inside a hardware **TEE** with keys fused into the processor — designed specifically to block both screen-recording and high-quality downloads ([Muvi: Widevine DRM explained](https://www.muvi.com/blogs/widevine-drm-all-you-need-to-know/)). Netflix/Prime cap the **L3 software CDM to 720p** and only send HD/4K down an **L1 + HDCP 2.2** chain.

L3 extraction *exists* — [tomer8007/widevine-l3-decryptor](https://github.com/tomer8007/widevine-l3-decryptor) (and the tbodt fork) — but it is: (a) limited to **SD/720p**, (b) **routinely patched** (the `widevinecdm` module is heavily obfuscated and Google rotates it), and (c) itself a **DMCA §1201 anti-circumvention act** — a separate offense from the copyright infringement. For an individual hobbyist, **L1 is effectively unbreakable.** Net consequence: you can't be the original ripper of HD legit content, so you're permanently downstream of, and exactly as fragile as, hosts like MegaCloud.

---

### 4. LEGAL — the existential category (no technical mitigation exists)

This is the pitfall that doesn't have a clever engineering workaround, and it's the one indie devs hand-wave the most.

#### 4.1 The PLSA felony

The U.S. **Protecting Lawful Streaming Act** (signed **27 Dec 2020**, part of the Consolidated Appropriations Act 2021) converted willful, for-profit commercial streaming from a misdemeanor to a **felony** ([Wikipedia](https://en.wikipedia.org/wiki/Protecting_Lawful_Streaming_Act), [USPTO](https://www.uspto.gov/ip-policy/enforcement-policy/protecting-lawful-streaming-act-2020)). Verified penalty tiers:

- **Up to 3 years** — base offense
- **Up to 5 years** — works being prepared for commercial public performance (pre-release)
- **Up to 10 years** — second/subsequent offense

The law was deliberately aimed at **providers/operators, not end-user viewers.** The "I'm just an aggregator / I only link" defense is **not reliable cover** once you host streams or proxy bytes — and it's jurisdiction-dependent even when you genuinely only link (linking to infringing material has been found infringing in some EU/US cases — *not legal advice, consult a lawyer*).

#### 4.2 Real operators, real prison time

| Case | Outcome | Detail |
|---|---|---|
| **Jetflicks** (Kristopher Dallmann) | **84 months / 7 years** (sentenced July 2025, surrender 17 Oct 2025) | Convicted June 2024; "largest internet piracy case to go to trial"; gov't est. **$37.5M**; 5 defendants sentenced (Huber 18mo, Polo ~5yr, Villarino 12mo) — [BleepingComputer](https://www.bleepingcomputer.com/news/security/operator-of-jetflix-illegal-streaming-service-gets-7-years-in-prison/), [The Record](https://therecord.media/five-sentenced-for-running-piracy-streaming-site) |
| **B9GOOD** (CODA/China) | **3 years imprisonment *suspended* for 3.5 years + RMB 1.8M fine** (26 Dec 2023) | First CODA-driven overseas conviction; 15-yr operation, 300M+ visits, **95% from Japan** — [CODA](https://coda-cj.jp/en/news/469/), [TorrentFreak](https://torrentfreak.com/china-sentences-pirate-site-operators-huge-win-for-japans-anime-industry-240304/) |
| **Fmovies** (Vietnam, ACE-assisted) | Operators **arrested Aug 2024** | "World's largest piracy ring"; note reports say they had **not yet been charged** — conviction status unconfirmed — [TorrentFreak](https://torrentfreak.com/fmovies-piracy-ring-was-shut-down-by-vietnam-assisted-by-ace-240829/), [ACE/PRNewswire](https://www.prnewswire.com/apac/news-releases/vietnamese-authorities-with-support-from-ace-take-down-worlds-largest-piracy-ring-302234134.html) |

> **Corrections note:** First-pass research said "B9GOOD operator **got 3 years** (China, 2023)." Materially imprecise — it was a **suspended** sentence (3 yrs suspended for 3 yrs 6 months) **plus an RMB 1.8M fine**, not 3 years of actual incarceration. Directionally right (he was convicted), but the suspension matters.

---

### 5. LEGAL/OPERATIONAL — the takedown & enforcement machine

Coordinated rightsholder + government pressure escalates predictably as you grow:

- **USTR Notorious Markets** listing is the on-ramp. **HiAnime was listed in both 2024 and 2025** (plus a 2025 "Priority Notorious Linking and Streaming Sites" category) and on the EU piracy watchlist; **MegaCloud was named as the backend.** Traffic at shutdown was huge — ~244M visits in Aug 2025 / 150M+ monthly cited ([USTR 2025 list PDF](https://ustr.gov/sites/default/files/files/Press/Releases/2026/2025%20Notorious%20Markets%20List%20(final).pdf), [CBR](https://www.cbr.com/hianime-america-government-notorious-market-list-2025/)).
- **GitHub purged 900+ anime repos/forks in March 2026** on a Remove Your Media / Crunchyroll / VIZ notice — including `aniwatch`, `aniwatch-api`, and `MegacloudKeys` ([TorrentFreak](https://torrentfreak.com/github-nukes-900-anime-piracy-repos-and-forks-but-rejects-circumvention-claims/)). Your tooling is impermanent; keep mirrors.
- **Enforcement coalitions:** MPA-led **ACE** (assisted Vietnam on Fmovies), Japan's **CODA** (B9GOOD), plus **FBI Operation 404** and **INTERPOL I-SOP** seizing domains/infrastructure.
- **AnimeHeaven** (11.6M Apr visits) had **all episodes nuked** after a Crunchyroll DMCA action ([Anime Corner](https://animecorner.me/animeheaven-piracy-site-nuked-after-crunchyroll-dmca-action/)).
- **HiAnime + 9anime went dark ~March 2026** after the USTR listing + Vietnam crackdown.

> **Corrections note (two distinct timelines — don't conflate):**
> 1. **The "900+ repos" was specifically "900+ forks across the targeted repositories,"** and — critically — **GitHub *rejected* the DMCA §1201 anti-circumvention theory** and removed the repos on *standard* copyright grounds instead. That undercuts the "MegacloudKeys is a circumvention tool" legal framing; the takedown stuck for ordinary infringement reasons, not §1201.
> 2. **"9anime shut down ~March 2026" is wrong.** 9anime (rebranded **AniWave**) was shut down in the **2024 ACE wave.** The **March 2026** shutdown is **HiAnime** (the `zoro.to → aniwatch.to → hianime` lineage). Keep the two separate. Also treat "permanently dead" as **unconfirmed** — successor/mirror domains and possible-return hints exist.

---

### 6. OPERATIONAL — the infrastructure deplatforming cascade

Every neutral vendor in your stack can cut you, and the trend is toward cutting you *faster*:

- **Cloudflare** has a DMCA **repeat-infringer termination policy** under 17 USC §512 and forwards complaints upstream ([abuse approach](https://www.cloudflare.com/trust-hub/abuse-approach/), [TorrentFreak](https://torrentfreak.com/copyright-holders-hold-cloudflare-liable-for-failing-to-terminate-repeat-infringers-210603/)). "Cloudflare in front" is a weakening shield, because —
- **A Tokyo court found Cloudflare liable for CDN-ing manga piracy (19 Nov 2025).** This pressures all CDNs to drop pirate customers faster.
- **Hosts** ban accounts for piracy; **registrars** suspend domains under court order/seizure.
- **Single points of failure cascade downward:** when `vidsrc.to` (Fmovies-linked) went down, it took *hundreds* of downstream movie sites with it. Depending on one upstream host means you inherit its death.

Mitigation (piracy-tolerant offshore hosts + Cloudflare-in-front + constant domain rotation) is fragile and escalating — it buys weeks, not permanence.

> **CRITICAL correction (biggest single error in first-pass research):** The Cloudflare manga-piracy judgment was **~500 million yen ≈ US$3.2–3.3 million**, **NOT ~$24 million.** The "~$24M" figure is **roughly 7–8x too high.** What happened: the Tokyo District Court *recognized* ~3.6 billion yen in total damages across four works, but plaintiffs (Shueisha, Kodansha, Shogakukan, Kadokawa) only *claimed* a portion, so the **order** was ~500M yen. Everything else first-pass said is correct: date (**19 Nov 2025**), "first global CDN held liable," secondhand-reported, and **not final — Cloudflare plans to appeal** ([Japan Times](https://www.japantimes.co.jp/news/2025/11/20/japan/crime-legal/cloudflare-manga-piracy/), [TorrentFreak](https://torrentfreak.com/tokyo-court-finds-cloudflare-liable-for-manga-piracy-in-long-running-lawsuit-liable-for-piracy-following-manga-publishers-lawsuit-251119/), [Kadokawa](https://group.kadokawa.co.jp/global/information/news_release/2025111901_en.html), [ANN](https://www.animenewsnetwork.com/news/2025-11-19/shueisha-kodansha-shogakukan-kadokawa-win-copyright-suit-against-cloudflare/.231199)).

---

### 7. OPERATIONAL/FINANCIAL — payment processor & ad-network bans

The legitimate money rails refuse the category outright, with no appeal:

- **Stripe & PayPal** prohibit piracy/adult/"high-risk"; accounts get **frozen, often with no appeal** ([Stripe high-risk/adult prohibitions](https://signaturepayments.com/does-stripe-allow-adult-content/)).
- **Google AdSense** stops serving ads on any DMCA'd page **and permanently blocks future AdSense on that page.**
- **Chargebacks above 1%** of volume flag the account high-risk → processor termination.

This forces you to shady high-risk/crypto processors at worse terms — which is the on-ramp to the next, worst pitfall.

---

### 8. SECURITY/REPUTATION — the malvertising trap

Locked out of clean ad demand, the **only** revenue available is from networks that don't police creatives: **Hilltopads, PopAds, ExoClick, EroAdvertising** (popunder/redirect). The documented consequence is that **you actively poison your own users:**

- **Malvertising = ~12% of pirate-site ads ≈ $121M/yr** (~$68.3M from US visits) — [Digital Citizens Alliance / White Bullet 2022](https://www.digitalcitizensalliance.org/news/press-releases-2022/piracy-to-ads-to-ransomware-investigation-finds-121-million-in-dangerous-malicious-ads-on-piracy-sites-designed-to-trick-users-into-infecting-their-devices/).
- **Advertising fuels a ~$1.34B/yr illegal piracy market** — [DCA / White Bullet 2021](https://www.digitalcitizensalliance.org/news/press-releases-2021/advertising-fuels-1.34-billion-illegal-piracy-market-report-by-digital-citizens-alliance-and-white-bullet-finds/).
- **~8 in 10 investigated pirate sites served malware-ridden ads;** popunders open hidden windows users never see.
- Post-shutdown **HiAnime clones (`.dk`/`.se`/`.cv`) are flagged as suspected phishing/malware** — a *secondary* reputational hit: your brand gets impersonated to attack the very users you trained to seek it out.

> **Corrections note:** the 12% / $121M / $1.34B figures are from **2021–2022** DCA/White Bullet reports — directionally valid but **dated**; treat as order-of-magnitude, not current.

There is **no mitigation that preserves revenue** — clean ads structurally will not run on a pirate site. You either harm your users or you have no income. This also feeds the legal loop: malvertising reinforces the "notorious market" designation.

---

### 9. BUSINESS — SEO demotion, no moat, no exit

The long-run value destruction that makes the whole thing pointless even if you dodge everything above:

- **Google's "Pirate Update"** demotes whole sites with many valid DMCA notices ([Search Engine Land](https://searchengineland.com/dmca-requests-now-used-in-googles-ranking-algorithm-130118)). Delisting from search is repeatedly cited as the **single highest-leverage anti-piracy move** — it strangles the organic traffic that makes piracy profitable in the first place.
- **No moat.** Your catalog is everyone else's catalog (the same MegaCloud backend). There's nothing defensible to build.
- **Forced rebrand churn resets your brand and SEO every time.** The `zoro.to → aniwatch.to → hianime` lineage is the proof: each domain hop torches accumulated brand/SEO equity, so you can **never compound** the two assets that matter.
- **No exit.** You cannot legally sell, raise capital on, or bank an infringing business. No clean acquirer, no bank, no equity event. The asset is **worth zero to anyone legitimate** — you are building something structurally unsellable.

---

### 10. The doom loops (how the domains reinforce each other)

1. **Technical loop:** upstream rotates AES key/domain → all clones break at once → you re-RE → repeat forever → maintainer burns out → repo archived / "NO LONGER FUNCTIONAL."
2. **Scraper loop:** Turnstile blocks HTTP clients → headless browsers/solvers → CF update + datacenter-IP burn → costlier residential proxies → repeat.
3. **Delivery/cost loop:** CORS forces an `m3u8` proxy → all video bytes flow through you → egress > ad revenue → migrate to R2/Bunny or stop proxying (accept breakage). Bandwidth, not features, dominates.
4. **Legal/operational cascade:** traffic grows → USTR listing → MPA/ACE/CODA/Crunchyroll DMCA + §1201 notices → GitHub purges tooling, AdSense disables pages, Google demotes you, CDN/host/registrar drop you, processors freeze funds → domain seizure / arrest. Each rebrand buys time and resets SEO; it never stops the cascade.
5. **Monetization trap:** banned from clean ads + processors → malvertising + crypto/high-risk pay → malware to users + chargebacks (>1% = processor death) → tanked retention + reinforced "notorious market" status → back to step 4.

---

### 11. Verdict for an indie developer

If you map all six domains, **the only two designs that aren't fatally exposed in *some* category are:**

| Path | Felony risk (PLSA) | Extractor treadmill | Malvertising forced? | Deplatforming cascade | Has an exit? |
|---|---|---|---|---|---|
| **Pirate aggregator (zoro/hianime clone)** | **Yes (up to 10 yr)** | **Yes, perpetual** | **Yes** | **Yes** | **No** |
| **Legal metadata/link-out aggregator** (licensed APIs, e.g. AniList/MAL/TMDB, AniList GraphQL, Crunchyroll/HIDIVE official) | No* | No (no stream extraction) | No (clean ads/subs OK) | No | **Yes** |
| **Self-host your own legally-acquired library** (Jellyfin/Plex on owned content) | No | No | No | No | n/a (personal) |

\* *Pure linking-out is jurisdiction- and fact-dependent — linking to known-infringing content has been found infringing in some EU/US cases. Use licensed/official APIs and link only to legal sources, and consult a lawyer.*

**Opinionated bottom line:** building the pirate clone means signing up for a perpetual reverse-engineering treadmill you can never win, on top of a felony exposure with people *actually in prison*, funded by malware you inject into your own users, with no moat and no exit. Every "fix" (proxy for CORS, residential proxies for scraping, offshore host, Cloudflare shield) creates a worse downstream problem (egress bills, $8/GB proxies, deplatforming, weakening shield). The legal aggregator or self-host paths sidestep the felony, the treadmill, the malvertising trap, **and** the deplatforming cascade *simultaneously* — which is why, for an indie dev, they're the only two designs worth a single line of code.
