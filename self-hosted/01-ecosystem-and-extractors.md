# 01 · How the anime-piracy ecosystem actually works

The landscape AniChan lives in, from primary sources (EverythingMoe Discord +
verified web research). Read this to understand *why* the plan is what it is.

## The tiers (where everyone sits)

| Tier | Stores | Examples | AniChan |
|------|--------|----------|---------|
| 1 · Embed-only | nothing; iframes a host player | most "new site" submissions | **today (via Miruro)** |
| 2 · Scraper + own proxy | metadata + scraped m3u8, served via own CF-Worker/VPS proxy | itachi.tv, AniLight, JustAnime, Anidap | partial (`watch.py`) |
| 3 · Cache-on-play | downloads segments on first play, serves own copy | ANIMO, AniKuro, PimpAnime | **Phase 1 target** |
| 4 · Bulk self-host | big pre-built library + host fallback | 2dhive (~19 TB, 70/30), coreflix | Phase 2+ |
| 5 · Release/encode | makes own encodes (AV1, upscale, own subs) | Hentai Ocean | not a goal |

The whole scene leans on the **same few upstream hosts**. The dominant one is
**MegaPlay = Anikoto = mewstream** (one operator — `noidea` confirms repeatedly:
*"it's not speculation, megaplay is anikoto"*). Others: VidNest/VidWish
(redirects to MegaPlay), Videasy, DropFile, AniLink, animepahe/kwik, AllAnime,
ok.ru, blogger. **Miruro** (what AniChan uses) is itself an aggregator over these
and the community ranks it ~#5 (*"content depends on the sites it scrapes"*).

## The real video host: MegaCloud (HiAnime's backend)

Aggregators don't host video — they embed a **third-party encrypted player**.
For the HiAnime family that's **MegaCloud** (the actual file host + player).
- MegaCloud protects stream URLs with **CryptoJS-AES, keys generated at runtime**,
  behind heavily-obfuscated JS (migrated from an earlier WASM scheme), with
  per-instance scrambled identifiers.
- Extractors recover the key by **AST-deobfuscating the JS** (control-flow
  unflattening, string-array decoding) and **pattern-matching known
  key-construction patterns** — so they **break whenever the obfuscation
  changes**. It's a permanent cat-and-mouse.

## ⚠️ The March 2026 extractor massacre (why we self-host)

The dominant open-source extractor toolchain is **legally dead, not technically
dead**:
- **2026-03-23**: GitHub DMCA-blocked `ghoshRitesh12/aniwatch-api` (**414+
  forks**), `ghoshRitesh12/aniwatch`, and `yogesh-hacker/MegacloudKeys` (the
  separately-distributed runtime key repo) — all now **HTTP 451**.
- Filed by **Remove Your Media LLC for Crunchyroll LLC + VIZ Media**, part of a
  **900+ repo sweep**. (GitHub rejected the §1201 "circumvention device" theory
  but removed them on other copyright grounds anyway.)
- **HiAnime itself went dark** in the 2024-2026 crackdown.

**Takeaway:** the entire tier-1/tier-2 path (scrape an extractor → embed/proxy a
host) sits on infrastructure that a rightsholder can erase with one notice. The
only durable position is **owning your bytes** (tier 3+). That is the thesis of
this whole initiative.

## Takedown history — what actually kills sites

ACE/MPA's 2024-2025 campaign killed **Aniwave, AnimeSuge, HiAnime** via domain +
host pressure. **AnimeHeaven** was nuked when **Crunchyroll's DMCA made its
*origin host* comply** — the catalog was replaced with an error string.

> **The origin host is the single point of failure.** Domains and Cloudflare you
> rotate in minutes; the box holding the bytes you cannot fake. Everything in
> [03-hosting-and-opsec.md](03-hosting-and-opsec.md) follows from this.

## Operator-confirmed facts (EverythingMoe Discord)

- MegaPlay = Anikoto (`noidea`, repeatedly).
- **Cloudflare forwards DMCA** — *"hide them as hosts by using a reverse proxy.
  (Cloudflare doesn't count, they forward)"* — `hentaiocean`.
- **Hetzner kicks piracy**, OVH tolerated — `grodondo` (Doujiva) fled Hetzner →
  OVH; R2 used *"for profile pictures and manga images"* only.
- **Cache-on-play = "self-hosted cache"** — `wtf.ryan` (ANIMO): *"those segments
  directly download to my vds so they can be reused"*; sources *"nyaa.si,
  animetosho, fallback only megaplay."*
- **Storage is the constraint** — `luc0131` (Kyren): *"bandwidth and storage costs
  become huge if you store everything"* → newer sites use **request systems**.
