# After HiAnime died: how anime sites really work in 2026 — and Miruro

*Deep investigation, June 2026, much of it verified live from `vast-canada-2`.
The user's thesis was right: **almost nobody self-hosts video.** The surviving
sites are thin catalog + anti-scrape wrapper around **third-party hosts**, and
the consensus #1 site — **Miruro** — is a metadata aggregator whose backend
"pipe" we **reverse-engineered and ran successfully from our own server**,
getting direct **m3u8 + English VTT for both sub and dub.***

> Companion docs: [how-anime-streaming-sites-work.md](how-anime-streaming-sites-work.md)
> (the 9-layer teardown of the dead HiAnime stack) and
> [host-integration-findings.md](host-integration-findings.md) (our working
> megaplay/vidwish path). This doc is the **2026 update**: what changed when
> HiAnime died, and the Miruro path that supersedes flaky MegaPlay.

---

## 0. TL;DR — the answer

- **HiAnime and AnimeKai are both dead** (Mar & May 2026). The old OSS monoculture
  (consumet, `ghoshRitesh12/aniwatch`) was DMCA-451'd off GitHub. "The new way"
  is **meta-aggregators that resolve streams server-side** + a long tail of
  small self-hosted single-source scrapers.
- **Miruro is the consensus successor** (~23M visits/mo, now the #1 free anime
  site). It is **not a host** — it's an AniList-metadata aggregator that fans out
  to ~7 rotating upstream providers and returns a **resolved m3u8 + multi-language
  VTT**.
- Miruro's backend speaks a single obfuscated endpoint, **`/api/secure/pipe`**.
  We decoded its envelope and **ran it live from vast-canada-2**: two calls →
  `{streams:[{m3u8, referer}], subtitles:[English.vtt, …]}`. The m3u8, its
  variant playlist, the segments, and the English VTT all fetch **HTTP 200** from
  our server, for **sub and dub**.
- **This is the reliable replacement for MegaPlay** (which is iframe-only and
  flaky): switch our watch page from an embedded MegaPlay iframe to **our own
  hls.js player fed by an m3u8 proxy**, with Miruro as the resolver and
  megaplay/vidwish as a fallback.

---

## 1. The 2026 reset — what died, what it means

| Event | Date | Source |
|---|---|---|
| **HiAnime** (zoro→aniwatch→hianime) goes offline ("time to say goodbye"), then permanently dead | ~Mar 13 → May 31 2026 | [Wikipedia/HiAnime](https://en.wikipedia.org/wiki/HiAnime) |
| **AnimeKai** dead (enforcement + a literal data-center fire) | ~May 10 2026 | [CBR](https://www.cbr.com/animekai-shutdown-official-end-of-anime-era-2026/) |
| **Crunchyroll/VIZ DMCA** removes **900+ repos/forks** (consumet, aniwatch, aniwatch-api, hianime-API, MegacloudKeys…) → **HTTP 451** | Mar 23 2026 | [github/dmca](https://github.com/github/dmca/blob/master/2026/03/2026-03-23-crunchyroll.md), [Collider](https://collider.com/crunchyroll-anti-piracy-github-removes-900-third-party-apps/) |
| **consumet** → self-host-only, provider files 451 at repo level | 2026 | [docs.consumet.org](https://docs.consumet.org/list-of-providers) |

Consequences that shape every design choice now:
- **No drop-in library.** `aniwatch`/`consumet` can't be `npm i`'d as a maintained
  dependency anymore. Whatever you build, you maintain.
- **"HiAnime is back" is a lie.** `hianime.vc`, `hianimez.to`, `hianime.city` are
  **unrelated copycat operators**, not the original team. Don't anchor on them.
- **The library didn't die — the brand did.** The actual HiAnime video catalog +
  its episode-ID scheme **survive** inside the **megaplay / vidwish / anikoto**
  host cluster (same operator), which is exactly what we already integrate.

---

## 2. How the aggregator sites are actually built (live teardown: anikoto.cz + aniwaves.ru)

The user pointed at `anikoto.cz` and `aniwaves.ru` ("they definitely use a 3rd-party
host — I want to know exactly how"). Confirmed, by reverse-engineering both live:

### They are the *same* software
Both run the **"Zoro/AniwatchTV clone" PHP template** (the one sold/ripped across
dozens of pirate sites). Proof:
- Byte-identical asset stack: jQuery 1.12.4, Bootstrap 4.6.1, Swiper 5.4.4,
  tooltipster, babel-polyfill, the `/ajax/episode/*` routes, the
  `HD-1 / Vidstream / VidCloud` server tabs.
- **`window.__cfg`** is an AES blob whose **encrypted prefix is identical** on both
  sites (`bMb5x0yIRgH29Id2/FoyKMh5w98rTeONb4XlRuOZGwo4FrB1SFPVr455NAglCToG…`) →
  same key, same code. They're the same script, reskinned.
- Difference is cosmetic: **anikoto** = English skin, `cdn.anipixcdn.co` thumbnails,
  Google **reCAPTCHA**; **aniwaves** = Russian skin, `static.aniwaves.ru`,
  `disgus.ru` comments, Cloudflare **Turnstile** (sitekey `0x4AAAAAACCWp1auqd8ivDmU`),
  and a popunder ad network (`pe.quellambrein.com`).

### The resolution chain (what happens when you click an episode)
```
GET /ajax/episode/list/{animeId}        (X-Requested-With: XMLHttpRequest)
   → episode anchors:
     <a data-id data-num data-mal="11061" data-sub="1" data-dub="1"
        data-ids="<double-base64 → AES ciphertext>">
GET /ajax/server/list?servers={data-ids}     → server tabs  #w-servers li[data-sv-id]
GET /ajax/sources?id={sv-id}&asi=&autoPlay=   → { link: "https://<3rd-party-embed>/…" }
   → set as <iframe src>, controlled by postMessage (skip-intro / next / fullscreen)
```
Verified live: `ajax/episode/list/68` returned the real episode list; the encrypted
`data-ids` blob double-base64-decodes to **AES ciphertext** (key hidden in the
obfuscated JS) — it encodes the **third-party host handles**. The episode anchor
also carries **`data-mal`** (the MAL id) — that's their metadata bridge.

### The point the user wanted proven
**They do not host video.** The site is a catalog + an encrypted-handle→embed
resolver. The actual bytes come from a **third-party host** loaded in an `<iframe>`
(the "Vidstream/VidCloud/HD-1" labels are cosmetic names over
megaplay/vidwish/vidtube/vibeplayer). The reCAPTCHA/Turnstile + `vrf` token +
AES'd `data-ids` exist **purely to stop people scraping the embed URL** — i.e. to
stop exactly what we did. `aniwaves.ru` is the identical script with a Russian
skin; it's *not* a different architecture, and it still embeds the same
third-party host family (not self-hosted, not Russian-CDN).

---

## 3. Miruro — the actual answer (profile + verified protocol)

### What it is
`miruro.to / .tv / .bz / .online / .ru` (+ more mirrors). As of June 2026 it's the
**single most-trafficked free anime site in English** (~23.8M visits/mo on
miruro.tv, surging as HiAnime/AnimeKai died — [Similarweb](https://www.similarweb.com/website/miruro.tv/)).
It is a **metadata-first aggregator**, not a host:
- Catalog/metadata from **AniList** (same as AniChan).
- Video fanned out across ~7 upstream providers (codenames **rotate** — live we
  saw `bonk, kiwi, ally, pewe, moo, bee, hop`; they map to the
  anikoto/nekostream/vidtube cluster **and** AllAnime/allmanga).
- **Sub and dub**, with soft **VTT** subtitles in ~11 languages.
- Frontend is open-source ([Miruro-no-kuon/Miruro](https://github.com/Miruro-no-kuon/Miruro),
  React/TS); **backend/scraper is closed** and run by an anonymous operator.

### The `/api/secure/pipe` protocol — DECODED & VERIFIED LIVE
Miruro's SPA talks to its backend through one obfuscated tunnel. We decoded the
envelope (cross-checked against [aryaniiil/anime-api](https://github.com/aryaniiil/anime-api)
"Kuhi" + [walterwhite-69/Miruro-API](https://github.com/walterwhite-69/Miruro-API))
and **ran it from vast-canada-2**:

```
ENDPOINT   GET https://www.miruro.bz/api/secure/pipe?e={ENC}
           (base: .bz works from our IP; .online is 000/dead from us — iterate bases)
HEADERS    User-Agent: <Chrome>,  Referer/Origin: https://www.miruro.to/,  Sec-Fetch-*: cors
REQUEST    ENC = base64url( json({ "path","method":"GET","query":{…},"body":null,"version":"0.1.0" }) ).rstrip("=")
RESPONSE   body → (pad) → base64url-decode → gzip-decompress → JSON
```

**Call 1 — episodes** (`path:"episodes"`, `query:{anilistId}`):
```json
{ "mappings": {…},
  "providers": { "bonk":{"episodes":{"sub":[{"id":"<b64>","number":1}, …]}}, "kiwi":{…}, … } }
```
- Each `id` is `base64( "<host>:<slug>:<handle>" )`, e.g. decodes to
  `anikoto:i-made-friends-…-lymhb:<handle>`. Providers carry `sub` and/or `dub`.

**Call 2 — sources** (`path:"sources"`, `query:{episodeId, provider, category, anilistId}`):
```json
{ "streams": [
    {"url":"https://mt.nekostream.site/<hash>/master.m3u8","type":"hls",
     "referer":"https://vidtube.site/","server":"VidPlay-1","default":true},
    {"url":"https://vidtube.site/stream/…/hsub","type":"embed","referer":"https://vidtube.site/"} ],
  "subtitles": [
    {"file":"https://mt.nekostream.site/<hash>/subtitles/English.vtt","label":"English",
     "language":"en","kind":"captions","format":"vtt","default":true}, … ] }
```

> ⚠️ **The one gotcha that cost an hour:** pass `episodeId` **exactly as returned**
> by the episodes call (it's already base64). Re-encoding it → **HTTP 444** (WAF
> reject). Kuhi's code *looks* like it re-encodes, but it decodes-then-encodes
> (net no-op); the wire value is the original base64 string.

### Live results from vast-canada-2 (the proof)
| Test | Result |
|---|---|
| `episodes` pipe (AniList 169580) | **200**, 7 providers, sub eps present |
| `sources` pipe (sub) | **200** → `master.m3u8` + 11 subtitle langs |
| Fetch `master.m3u8` (w/ `Referer: vidtube.site`) | **200**, valid `#EXTM3U` |
| Fetch variant playlist | **200**, real segments |
| Fetch `English.vtt` | **200**, `WEBVTT` |
| **DUB** (AniList 16498 AoT ep1, `dub`) | **200** m3u8 via `ally`→AllAnime `repackager.wixmp.com` (`Referer: allmanga.to`) |

11 subtitle languages observed: English, Portuguese, Spanish(×2), Arabic, French,
German, Italian, Russian, Chinese(×2).

**Bonus:** the *dub* resolved to **AllAnime/allmanga's** wixmp CDN — the exact
source that Cloudflare-blocks us when we hit its API directly ([allanime-api-blocked]).
Via Miruro's pipe we get the final CDN m3u8 **without** touching AllAnime's
Turnstile. Miruro does the extraction; we just fetch open CDN bytes with the right
referer.

### The 7 providers = 7 *independent* hosts — and Miruro only resolves, never hosts

Enumerated **all** providers for AniList 16498 from vast-canada-2 and fetched each
resolved m3u8 directly. Every stream URL sits on the **host's own CDN** — zero
`miruro.*` domains — so Miruro carries no video bandwidth; it's a pure
resolver/extractor.

| Miruro provider | Real host | sub/dub | resolved m3u8 CDN | direct fetch (our datacenter IP) |
|---|---|---|---|---|
| `ally` | **AllAnime** (allmanga) | sub+dub | repackager.wixmp.com | **200 ✓** |
| `pewe` | **AniDB.app** | sub+dub | hls.anidb.app | **200 ✓** |
| `moo` | **AnimeGG** | sub | — | (transient miss) |
| `bee` | **Anikoto/MegaPlay** | sub+dub | cdn.mewstream.buzz | **403** (MegaPlay's locked CDN; VidWish twin is open) |
| `kiwi` | **AnimePahe** | sub+dub | vault-13.owocdn.top | **200 ✓** |
| `hop` | **KickAssAnime** | sub+dub | hls.krussdomi.com | **200 ✓** |
| `bonk` | **AnimeDao** | sub+dub | vibeplayer.site | **200 ✓** |

**There are two independent gates, and we only ever hit the easy one:**
1. **Resolution API** (AniList id → m3u8 URL): per-host encryption + anti-bot that
   **blocks datacenter IPs** — this is where we "got rejected" on AllAnime. *Miruro
   does this step for us* (from un-blocked infra), and it covers all 7 hosts at once.
2. **CDN bytes** (the m3u8 itself): mostly **open** — **5/6 fetch HTTP 200** from our
   datacenter with the right `Referer`. Our proxy serves these; Miruro touches none
   of the bandwidth.

Ironically the one **locked** CDN (`cdn.mewstream.buzz`) is **MegaPlay's** — the host
we currently depend on — while the *other 5* hosts Miruro surfaces are openly
fetchable. **Resilience implication:** run a **layered resolver** — our own
megaplay/vidwish + animepahe direct paths as independent primaries, Miruro as the
"other-6-hosts + fallback" resolver — so **no single resolver (Miruro included) is a
hard dependency**, and the bytes always come from open host CDNs via our own proxy.

### How Miruro maps AniList → each host — and how to reproduce it WITHOUT Miruro

Miruro's mapping is **not proprietary** — it orchestrates two **public** services we
verified return HTTP 200 from vast-canada-2:

1. **ani.zip** (`https://api.ani.zip/mappings?anilist_id={id}`) — the universal ID
   table. Miruro's `mappings` object **is this verbatim**: `malId, anidbId, kitsuId,
   animePlanetId, anisearchId, simklId, imdbId, themoviedbId, thetvdbId, livechartId,
   annId, animescheduleId, animethemesId, animefillerlistId` + **`aniskip`**
   (intro/outro skip times) + `episodeOffset`/`defaultTvdbSeason` (multi-season
   episode alignment).
2. **MALSync** (`https://api.malsync.moe/mal/anime/{malId}`) — MAL id → each host's
   native slug. **Verified identical to Miruro's slugs**: MALSync returns
   `animepahe → "49"` and `KickAssAnime → "attack-on-titan-fa99"`, exactly matching
   Miruro's `kiwi`/`hop` ids. (So Miruro literally uses MALSync for those providers.)

Each provider's episode `id` decodes to **`<host>:<host's-native-slug>:<handle>`**, e.g.
`allmanga:wbnpCxPu3fyk9XSaZ:…`, `anikoto:attack-on-titan-bgaoa:…`, `animepahe:49:…`.
For hosts MALSync doesn't cover (anikoto, allmanga, animegg, animedao, anidbapp),
the slug is obtained by **searching that host's own catalog** by title/MAL — the
classic fuzzy-match (Dice + format/year gate, see Layer 1 of
[how-anime-streaming-sites-work.md](how-anime-streaming-sites-work.md)).

**Can we resolve each host ourselves? Native-API reachability from our datacenter IP:**

| host | native API from our server | resolve without Miruro? |
|---|---|---|
| **megaplay/anikoto** | 200 | ✅ already do — AniList-direct `stream/ani/{id}/{ep}/{lang}` |
| **animepahe** | 200 (no CF challenge) | ✅ yes — MALSync id `49` → release API → kwik → m3u8 |
| **animegg** | 200 | ✅ yes |
| **animedao** | 200 | ✅ yes (→ vibeplayer CDN, already fetch 200) |
| **kickassanime** (kaa.lt) | **521** (CF) | ❌ needs Miruro/bypass |
| **allmanga / AllAnime** | **403** (CF/Turnstile) | ❌ needs Miruro/bypass ([allanime-api-blocked]) |
| **anidb.app** | **403** (CF) | ❌ needs Miruro/bypass |

**Conclusion — Miruro is reducible to an optional fallback, not a dependency:**
- **Mapping: 100% ours.** We already store AniList id + `idMal`; add **ani.zip**
  (cross-ids + aniskip + offsets) and **MALSync** (per-host slugs) — both public and
  reachable — plus per-host title-search for the rest. This reproduces Miruro's
  `mappings` + `providers` slug table exactly.
- **Resolution: 4 of 7 hosts are ours directly** (megaplay/anikoto, animepahe,
  animegg, animedao — all 200 from our IP). Miruro is only needed for the **3**
  IP-blocked hosts (allmanga, kickassanime, anidb.app), and even then purely as a
  resolver — the bytes still come from those hosts' open CDNs.
- So the durable design is **our own per-host mappers + extractors for the 4 reachable
  hosts, with Miruro as a thin fallback for the 3 blocked ones.** If Miruro vanishes
  we keep 4 independent sub+dub sources; no single site is load-bearing.

---

## 4. Surviving hosts (where the bytes actually live, June 2026)

| Host | Alive? | Sub/Dub | m3u8 or iframe | Notes |
|---|---|---|---|---|
| **megaplay.buzz** (HiAnime library) | ✅ surging | Both | **iframe-only** | full old-HiAnime catalog; legacy ep IDs valid; MegaCloud backend (JA3/JA4 TLS gate) |
| **vidwish.live** | ✅ | Both | iframe (its CDN `*.watching.onl` is fetchable) | sister of megaplay; **our current working path** |
| **anikoto** + `anikotoapi.site` | ✅ | Both | catalog JSON → megaplay iframe | the front-end for the same library |
| **animepahe** + Kwik | ✅ durable | Both | **real m3u8** | behind Cloudflare; obfuscated Kwik JS; the independent holdout |
| **AllAnime/allmanga** (wixmp CDN) | ✅ | Both | m3u8 (via Miruro) | direct API is Turnstile-blocked from us; reachable **through Miruro** |
| **Animetsu** (ex-Gojo) | ✅ | Both | aggregator | rising AniList-style front-end |
| **AnimeOwl** | ✅ | Both | mixed | fast simulcasts |
| **AnimeKai** + megaup | ❌ **dead** | — | — | gone May 2026; extractor knowledge is reference-only |

Anti-bot reality: MegaCloud (megaplay/vidwish) does **JA3/JA4 TLS fingerprinting**
— plain Node/fetch is blocked at the handshake even with perfect headers. This is
*the* reason resolving it ourselves is fragile, and why **letting Miruro resolve**
(then just fetching the open CDN m3u8) is more robust.

---

## 5. Surviving open-source scrapers worth knowing

| Repo | Stack | Source | Returns | Notes |
|---|---|---|---|---|
| [aryaniiil/anime-api](https://github.com/aryaniiil/anime-api) ("Kuhi") | **FastAPI + httpx** | **Miruro pipe** | m3u8 + subs + built-in `/proxy_m3u8` | **same stack as our backend**; the reference we cloned. Provider ranking is stale (`zoro/bee/kiwi…` vs live `bonk/ally/pewe…`) — rank dynamically. |
| [walterwhite-69/Miruro-API](https://github.com/walterwhite-69/Miruro-API) | Python (Docker) | Miruro pipe | m3u8 + VTT + intro/outro | "fully decrypted native Python… bypasses the WebCrypto pipe." Most complete Miruro shim. |
| [hexxt-git/anime-sdk](https://github.com/hexxt-git/anime-sdk) | TypeScript | AllAnime, Gogo, **AniKoto, MegaPlay** | m3u8 + VTT, **ships HMAC-signed `/proxy`** | most modern multi-source; live E2E tests |
| [ElijahCodes12345/animepahe-api](https://github.com/ElijahCodes12345/animepahe-api) | JS | AnimePahe | m3u8 | most-starred pahe API |
| [Shineii86/AniKotoAPI](https://github.com/Shineii86/AniKotoAPI) | JS (Vercel) | AniKoto→MegaPlay | **embed URLs** | matches our current MegaPlay path |

Dead/avoid: `ghoshRitesh12/aniwatch(+api)`, `yahyaMomin/hianime-API`,
`itzzzme/anime-api` (all **451**); `walterwhite-69/AnimeKAI-API` (target dead);
`*/hianime-api` forks pointing at the dead hianime.to or the .vc copycats.

---

## 6. Recommendation for AniChan (the build)

**Adopt the Miruro pipe as our primary stream resolver, behind our own player.**
This replaces the flaky MegaPlay *iframe* with a player **we control**.

1. **Backend** `app/sources.py` (new): a thin async client for the Miruro pipe
   (httpx — we already use it). Two functions: `pipe_episodes(anilist_id)` and
   `pipe_sources(anilist_id, provider, category, episode_id)`. Iterate the base
   domains (`www.miruro.bz`, `.to`, `.tv`, `.ru`) for resilience; **never hardcode
   provider names** — rank whatever `providers` come back (prefer ones exposing the
   wanted `category`, then by stream count). Send `episodeId` **as-is**.
2. **Endpoint** `GET /watch/sources?anilistId&ep&category` → `{streams, subtitles}`
   (our shape). Cache the **episodes mapping** (anilistId→providers/handles) in
   Mongo (durable, few KB); **never cache the m3u8** (token/session-bound, expires).
3. **m3u8 proxy** (`/m3u8-proxy?url=&headers=`): fetch with the **per-stream
   `referer`** Miruro hands us (e.g. `vidtube.site`, `allmanga.to`), rewrite child
   URIs back through the proxy, stamp CORS, Range-passthrough. Pattern is in
   [how-anime-streaming-sites-work.md](how-anime-streaming-sites-work.md) Layer 4
   and Kuhi's `main.py`.
4. **Frontend** watch page: swap the MegaPlay `<iframe>` for **hls.js → `<video>`**
   loading the proxied master playlist, attach the VTT `<track>`s (default
   English), wire intro/outro skip if present, and a server/quality switcher that
   re-calls `/watch/sources` with a different provider/category.
5. **Fallback chain:** Miruro pipe → (on miss) our existing **megaplay/vidwish
   direct** path ([host-integration-findings.md](host-integration-findings.md)) →
   (independent) **animepahe/Kwik**. Different operators = real resilience.

### Maintenance / caveats
- **Miruro rotates** provider codenames *and* base domains, and obfuscates the
  pipe. Build for rotation (iterate bases, rank providers dynamically, alert on
  all-bases-fail). Expect periodic breakage — same treadmill as everyone, but the
  *envelope* (base64url+gzip JSON, `path/query` RPC) has been stable.
- **We depend on a third party** (Miruro's closed backend). That's the same posture
  as MegaPlay, but Miruro is bigger, multi-source, and currently the most reliable
  — and our AniList catalog stays fully independent, so a Miruro outage degrades to
  the megaplay/pahe fallbacks, never to "site down."
- **Legal posture is unchanged** from MegaPlay: proxying third-party m3u8 is the
  same exposure as embedding their iframe (see Layer 8/9 in the companion doc). No
  worse, somewhat better UX/control.
