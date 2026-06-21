# Host Integration Findings (the key reverse-engineering)

*Discovered live from a residential KG IP, June 2026. This is the heart of the
project: how to turn an AniList id into a playable `.m3u8` without Cloudflare or
clicks. Everything here was verified end-to-end with real requests.*

## TL;DR — the working pipeline

```
AniList id ──► MegaPlay  /stream/ani/{anilistId}/{ep}/{sub|dub}  ──► data-realid (HiAnime ep id)
realid     ──► VidWish   /stream/s-2/{realid}/{sub|dub} → data-id → /stream/getSources?id=…
           ──► { m3u8 on *.watching.onl, 9-language .vtt subs, intro/outro skip }
m3u8       ──► OUR proxy (inject  Referer: https://vidwish.live/  + CORS) ──► hls.js → plays
```

No Cloudflare challenge, no human clicks, reachable from a flagged residential IP.

---

## 1. The landscape we tested (and what's dead)

| Source | Status from our IP | Notes |
|---|---|---|
| **anikoto** (anikototv.to / anikoto.cz) | ✅ alive, no CF | a **competitor aggregator**, not a source — but it led us to the hosts |
| **MegaPlay** (megaplay.buzz) | ✅ alive, no CF | the actual host (HiAnime library); public webmaster API |
| **VidWish** (vidwish.live) | ✅ alive, no CF | MegaPlay's twin; **its CDN is the one that lets us fetch** |
| **VibePlayer** (vibeplayer.site) | ✅ alive | animepahe-based, *different operator*, direct m3u8 |
| allanime (allmanga.to / api.allanime.day) | 🔴 Cloudflare **Turnstile loop** (4–5 clicks) | works only behind a clean IP / VPN |
| animepahe | 🔴 Cloudflare Turnstile | same pain |
| hianime / zoro / kaido / 9anime / megacloud | ⛔ **dead / timeout** | gone; do not pursue — "the canceled ones have no new anime" |
| consumet / aniwatch-api public hosts | ⛔ 451 / 500 | dead |

**Why our IP matters:** `api.allanime.day` returns `cf-mitigated: challenge` (interactive
Turnstile) to our KG residential IP, and even Chrome-TLS impersonation (`curl_cffi`)
and a headless browser couldn't pass it cleanly (challenge loop). MegaPlay/VidWish
have **no such challenge** — that's why they win.

---

## 2. Who owns what (important for resilience)

- **anikoto = MegaPlay = VidWish = same operator.** Proof: `vidwish.live/api` is a
  572-byte page that JS-redirects to `https://megaplay.buzz/api`; MegaPlay's docs are
  branded *"Anikoto video API"* and point to `https://anikotoapi.site`.
- So MegaPlay + VidWish are **one operator** — convenient but a single point of failure.
- **VibePlayer (animepahe) is a different operator** → our independent fallback host.
- The "server names" in anikoto's UI (**HD-1, Vidstream-2, VidCloud-1, VidPlay-1, Kiwi**)
  are **cosmetic labels**, not distinct tech. Real mapping:
  - HD-1 → megaplay.buzz (slot `s-5`)  •  Vidstream-2 → megaplay.buzz (slot `s-2`)
  - VidCloud-1 → **vidwish.live**  •  VidPlay-1 → vidtube.site  •  Kiwi → vibeplayer.site
  - i.e. HD-1 and Vidstream-2 are **literally the same host** (MegaPlay).

---

## 3. The MegaPlay / VidWish protocol (verified)

### 3a. Discovery — AniList id → realid (MegaPlay)
```
GET https://megaplay.buzz/stream/ani/{anilistId}/{ep}/{sub|dub}
    Header: Referer: https://megaplay.buzz/        (any referer present; direct access "disabled")
→ HTML embed page containing:
    <div id="megaplay-player" data-id="13461" data-realid="107257" data-mediaid="672">
```
- `data-realid` (e.g. **107257**) = the HiAnime episode id, shared across MegaPlay & VidWish.
- Also accepts `/stream/mal/{malId}/{ep}/{lang}`. AniList endpoint is simplest (our catalog is AniList).
- Caveat (per docs): "not every show is synced to MAL/AniList yet" → fallback is the
  Anikoto discovery API (below) to get the realid by title.

### 3b. Stream — realid → m3u8 (VidWish)
```
GET https://vidwish.live/stream/s-2/{realid}/{sub|dub}
    Header: Referer: https://vidwish.live/
→ <div ... data-id="16836">
GET https://vidwish.live/stream/getSources?id=16836
    Headers: Referer: <embed url>, X-Requested-With: XMLHttpRequest
→ {
    "sources": { "file": "https://fxpy7.watching.onl/anime/<hash>/<hash>/master.m3u8" },
    "tracks":  [ {file:"…/eng-2.vtt", label:"English", kind:"captions"}, … 9 langs … ],
    "intro": {start,end}, "outro": {start,end}   // when present
  }
```
- **PLAINTEXT** — no crypto, no key. (Contrast: the dead MegaCloud needed AES + RC4.)
- 9 subtitle languages observed: Arabic, English, French, German, Italian,
  Portuguese-BR, Russian, Spanish (+ more per title).

### 3c. The CDN fetch — the one gotcha (403 vs 200)
Same content, two CDNs, different behaviour:

| Host | getSources m3u8 host | Direct fetch result |
|---|---|---|
| MegaPlay | `cdn.mewstream.buzz` | 🔴 **403** on every Referer/Origin/Sec-Fetch combo — locked |
| **VidWish** | `*.watching.onl` | 🟢 **200** with `Referer: https://vidwish.live/` |

**Conclusion:** get the `realid` from MegaPlay (AniList-keyed), but resolve the actual
stream via **VidWish** (its CDN is proxyable). Both share the realid, so they're interchangeable for discovery; only VidWish's CDN serves us bytes. Our proxy must inject
`Referer: https://vidwish.live/` when fetching the m3u8/segments.

---

## 4. The Anikoto discovery/catalog API (for resilience + fallback realid)

`https://anikotoapi.site` — free, branded "Anikoto video API". Mirrors the full
HiAnime library. (This is a *competitor's* API; we use it only as a fallback id source
and a catalog mirror — our primary catalog is AniList.)

**`GET /recent-anime?page=N&per_page=M`** — paginated catalog (**8,828 anime total**):
```
{ ok, anikoto_domains:["anikototv.to","anikoto.cz"],
  pagination:{page,per_page,total,total_pages},
  data:[ { id, title, alternative, titles(all synonyms), native, slug,
           rating, poster, is_sub(count), is_dub(count), description } ] }
```

**`GET /series/{id}`** — series + episodes:
```
data.anime:{…}
data.episodes:[ { id, title, jp_title, number,
                  episode_embed_id:"107257",            // == the realid
                  embed_url:{ sub:"megaplay.buzz/stream/s-2/107257/sub",
                              dub:"…/dub" },
                  updated_at } ]
```
- Confirms **sub/dub availability per series** via `is_sub` / `is_dub` counts,
  and per episode via which `embed_url` keys exist.
- `episode_embed_id` = the realid → a second way to get it (by title-matched anikoto id)
  if MegaPlay's AniList endpoint lacks a show.

### How to know what has dub vs sub-only
- Series level: `is_dub` count (0 = sub only). Frieren `is_dub:28`; Flowers of Evil `is_dub:0`.
- Anikoto frontend episode list also tags each episode `data-sub="1"` / `data-dub="0"`.

---

## 5. VibePlayer (the independent fallback host)

- `vibeplayer.site/public/stream/<id>/master.m3u8` = **direct m3u8**, fetched 200 with
  **no referer** (open CDN).
- Different operator (animepahe lineage) → real resilience if the Anikoto stack dies.
- Downside: discovery currently needs nekostream (anikoto's aggregator), so getting the
  vibeplayer id independently is the open problem for this host. Use as a secondary.

---

## 6. What to store in our DB (resilience)

Cache everything **except the video** (which expires / would make us a host):

| Store ✅ (durable, few MB total) | Don't ❌ |
|---|---|
| Catalog: id, titles, synonyms, slug, poster, description, sub/dub counts | resolved `.m3u8` URLs (token/session-bound, expire in hrs) |
| Episodes: number, title, **realid per host**, has_sub/has_dub | the video bytes (self-hosting = storage+legal, out of scope) |
| AniList ↔ realid ↔ host-id **mappings** (the gold) | |
| Subtitle `.vtt` **contents** (KB each, durable) | |
| intro/outro skip timestamps | |
| `anikoto_domains` (to follow domain rotation) | |

**Resilience logic:**
- discovery API dies, host lives → stored catalog + realids keep us streaming. ✅
- a host dies → switch host (store realids for MegaPlay/VidWish/VibePlayer). ✅
- whole Anikoto ecosystem dies → AniList catalog is independent; swap stream layer. ✅

---

## 7. Decisions locked from this investigation

1. **Primary host:** MegaPlay (realid discovery, AniList-keyed) → **VidWish** (stream, fetchable CDN). Same operator (Anikoto), but the cleanest working path.
2. **Independent host #2:** VibePlayer (animepahe) — different operator.
3. **Proxy must inject `Referer: https://vidwish.live/`** for the m3u8 + segments + (likely) subtitles.
4. **No Cloudflare, no browser, no clicks** on this path — `curl_cffi` (Chrome TLS) is enough; Playwright is only needed for the allanime/VPN fallback.
5. **anikoto/allanime are competitors, not providers** — we integrate the *hosts* directly and owe the aggregators nothing (except, optionally, the anikotoapi catalog mirror as a fallback id source).
