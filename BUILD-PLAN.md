# BUILD-PLAN — Anime Streaming Clone (hianime-faithful, provider-abstracted)

> **Scope:** a local **pet project** that faithfully reproduces the hianime/zoro
> architecture so you understand the real machine end-to-end. Provider-abstracted
> so you go **easy provider first → MegaCloud/hianime as the boss level** without
> rewrites. Run it locally for yourself. (Public deployment of pirated licensed
> anime = copyright infringement + a US felony if monetized — that decision is yours,
> and this plan does not cover the "operate an illegal business" layer.)
>
> Companion research (the "how it works"): see
> [`research/how-anime-streaming-sites-work.md`](research/how-anime-streaming-sites-work.md),
> [`research/solutions-cost-monetization-pitfalls.md`](research/solutions-cost-monetization-pitfalls.md).

---

## 0. The thesis the whole plan rests on

The system splits cleanly into a **durable half** and a **radioactive half**:

| Durable (the product — your time goes here) | Radioactive (rented, swappable, breaks quarterly) |
|---|---|
| Next.js UI, route map, component inventory | Per-host **extractors** (MegaCloud crypto, gogo AES, …) |
| AniList metadata layer (legit public API) | **m3u8/CORS proxy** (segment relaying) |
| hls.js + Artplayer/Vidstack player UX | Community **key feeds** (`itzzzme/megacloud-keys`, …) |
| AniSkip skip-intro, continue-watching | The scraper's HTML/JS parsing (obfuscated, moving target) |

**Architectural rule #1:** everything radioactive sits behind **one `AnimeProvider`
interface** and your own `/api` routes. You can swap a dead provider in an afternoon
and never touch the UI. This is exactly how `consumet` is built and why it survived
while individual sites died.

---

## 1. High-level architecture

```
┌─────────────────────────────────────────────────────────────┐
│ apps/web  — Next.js 15 App Router (the durable product)       │
│   /, /search, /anime/[id], /watch/[id]/[ep], /api/*           │
│   AniList catalog · Artplayer+hls.js · AniSkip · localStorage │
└───────────────┬───────────────────────────────┬─────────────┘
                │ (catalog/metadata)             │ (resolve stream)
                ▼                                 ▼
   ┌────────────────────────┐     ┌──────────────────────────────────────┐
   │ AniList GraphQL         │     │ packages/providers (the interface)    │
   │ graphql.anilist.co      │     │   AnimeProvider:                       │
   │ trending/search/detail  │     │     search · info · episodes ·         │
   │ "what exists"           │     │     servers · sources(→ m3u8+subs+skip) │
   └────────────────────────┘     │   impls: AllAnime → Gogo → HiAnime     │
                                   └───────────────┬──────────────────────┘
                                                   │ m3u8 is Referer/CORS-locked
                                                   ▼
                                   ┌──────────────────────────────────────┐
                                   │ services/proxy — m3u8 + ts + vtt proxy │
                                   │   inject Referer/Origin/UA upstream    │
                                   │   rewrite EVERY segment/key/variant    │
                                   │   stamp Access-Control-Allow-Origin:*  │
                                   └──────────────────────────────────────┘
```

**Two services + one app:**
1. `apps/web` — the Next.js frontend + its `/api` route handlers (provider calls live here in dev).
2. `services/proxy` — a standalone m3u8/segment proxy (separate because it relays *bytes* — never put this in Next serverless functions at any real scale; locally it's fine to run as a tiny Node/Hono process or even a Next route while learning).
3. `packages/providers` — the provider interface + per-host extractors, importable by both.

---

## 2. Tech stack (pinned, opinionated)

| Layer | Choice | Why |
|---|---|---|
| Framework | **Next.js 15 (App Router) + React 18 + TypeScript** | Keeps scraper URL/headers/keys **server-side**, gives ISR'd catalog pages. (SPA/Vite leaks `VITE_*` secrets + bad SEO — see research.) |
| Styling | **Tailwind CSS** | Matches every reference clone (AniTeams, Airin). |
| Catalog API | **AniList GraphQL** (`graphql.anilist.co`) | Legit public API; the catalog source of truth. 30 req/min (degraded) — cache it. |
| Player engine | **hls.js** (primary) **+ native Safari HLS fallback** | iOS has no MSE → hls.js *cannot* run there. The Safari branch is mandatory, not optional. |
| Player shell | **Artplayer** (vanilla, ~55KB) | Purpose-built `customType.m3u8` hook, official VTT-thumbnail/quality/multi-sub plugins. (Vidstack if you prefer React-native; Plyr has no HLS quality menu — avoid.) |
| Skip intro/outro | **AniSkip v2** (`api.aniskip.com`) + provider's own `intro/outro` | Independent of the radioactive scraper; stays alive. |
| Carousels | **swiper ^11** | Home rails. |
| Cache | **lru-cache** (dev) → **Redis/Upstash** (later) | Scrapers are slow + rate-limited; cache *metadata only*, never streams. |
| HiAnime extractor | **`aniwatch` npm @2.27.9** (vendored/pinned) | Source repo is DMCA-451'd on GitHub but **npm still installs**. Pin the known-good artifact. |
| Proxy | **Node + Hono** (or Cloudflare Worker) | Standalone, streams bytes. Reference: `itzzzme/m3u8proxy`, `JulzOhern/GOGOANIME-PROXY`. |
| Mapping | **MAL-Sync** (`api.malsync.moe`) + title-match fallback | Bridge AniList id → provider slug (the hard non-crypto problem). |

> Don't hot-load player libs from a CDN/repo that can vanish — **vendor/self-host** them (Vidstack defaults to pulling hls.js from jsDelivr; override it).

---

## 3. Repo layout

```
anime/
├─ apps/web/                      # Next.js 15 app
│  ├─ app/
│  │  ├─ page.tsx                 # home rails (ISR ~1h)
│  │  ├─ search/page.tsx          # dynamic search
│  │  ├─ anime/[id]/page.tsx      # detail + episode grid (ISR ~1h)
│  │  ├─ watch/[id]/[ep]/page.tsx # player (dynamic; sources never cached)
│  │  └─ api/
│  │     ├─ sources/route.ts      # calls provider.sources(), returns proxied m3u8 URL
│  │     ├─ anime/[id]/route.ts   # provider info+episodes (cached)
│  │     └─ search/route.ts
│  ├─ components/                 # AnimeCard, EpisodeGrid, Player, ServerSwitcher, Rails…
│  └─ lib/anilist.ts              # GraphQL queries
├─ packages/providers/           # the swappable half
│  ├─ types.ts                    # normalized AnimeProvider + result types
│  ├─ allanime.ts                 # EASY — build first
│  ├─ gogoanime.ts                # MEDIUM — second
│  ├─ hianime.ts                  # BOSS — wraps `aniwatch` npm / megacloud decrypt
│  └─ index.ts                    # provider registry + fallback chain
├─ services/proxy/               # standalone m3u8/ts/vtt proxy (Hono or CF Worker)
└─ claude/research/              # the research docs (already here)
```

(For a pet project you can collapse this into one Next app + a `lib/providers` folder
and a `proxy.ts` route — but keep the **interface boundary** even if it's one repo.)

---

## 4. The core abstraction — `AnimeProvider`

This interface is the spine. Every host implements it; the UI only ever sees the
normalized types. Normalizing the two real-world schemas (aniwatch vs consumet) lives here.

```ts
// packages/providers/types.ts
export interface AnimeProvider {
  id: 'allanime' | 'gogoanime' | 'hianime';
  search(query: string): Promise<SearchResult[]>;
  info(providerAnimeId: string): Promise<AnimeInfo>;
  episodes(providerAnimeId: string): Promise<Episode[]>;
  servers(episodeId: string, category: Category): Promise<Server[]>;
  sources(episodeId: string, server: string, category: Category): Promise<Sources>;
}

export type Category = 'sub' | 'dub' | 'raw';

export interface Sources {
  m3u8: string;                 // master playlist (still Referer-locked!)
  headers: Record<string,string>; // Referer/Origin/UA you MUST replay via the proxy
  subtitles: { url: string; lang: string; default?: boolean }[]; // WebVTT
  thumbnails?: string;          // VTT sprite track
  intro?: { start: number; end: number };
  outro?: { start: number; end: number };
}
```

The watch page never calls a provider directly — it calls `/api/sources`, which calls
the provider, then **rewrites `m3u8` through `services/proxy`** (passing `headers`) and
returns a browser-playable URL.

---

## 5. The m3u8 proxy (the piece that makes playback possible)

The `.m3u8` and its `.ts`/`.key` segments **403 without the right `Referer`**, and the
browser blocks cross-origin anyway. The proxy must:

1. Fetch the requested playlist/segment **with injected `Referer`/`Origin`/`User-Agent`** (from `Sources.headers`).
2. For playlists: **rewrite every URI** to route back through the proxy —
   `EXT-X-STREAM-INF` (variant playlists), `EXTINF` (segments), `EXT-X-KEY` (AES-128 key),
   `EXT-X-MAP`, `EXT-X-MEDIA` (audio/subs). **Miss the key URI → cryptic decrypt errors, not a clean 403.**
3. Stamp `Access-Control-Allow-Origin: *`.
4. For segments: forward `Range` → respond `206 Partial Content`, pipe bytes through.

```
GET /proxy?url=<enc m3u8 url>&headers=<enc JSON>
GET /proxy?url=<enc segment url>&headers=<enc JSON>   # same endpoint, recursive
```

Reference implementations to read (don't trust ephemeral hosted ones):
`itzzzme/m3u8proxy`, `Eltik/M3U8-Proxy`, `JulzOhern/GOGOANIME-PROXY` (recursive rewrite).

**Bandwidth warning:** every streamed byte transits this. Local = free. Deployed = this is
*the* cost (see cost doc) — use a Cloudflare Worker / cheap egress host, never a metered
serverless function. Don't worry about it for the pet project; just know where the cliff is.

---

## 6. The extractor ladder (easy → boss)

| Order | Provider | Extraction | Effort |
|---|---|---|---|
| 1st | **allanime** | clean-ish API, minimal obfuscation (what `ani-cli` uses) | 🟢 days |
| 2nd | **gogoanime** | AES-128, key+iv scraped from the embed page (`encrypt-ajax.php`) | 🟡 |
| boss | **hianime / MegaCloud** | `getSources` → decrypt (v2 hex passphrase from key feed; **v3 custom non-AES 3-layer cipher**) | 🔴 quarterly war |

**For the boss, don't hand-port the cipher first.** Wrap the pinned **`aniwatch` npm lib**
(it already implements all 4 eras + `megaplay.buzz` plaintext fallback) behind your
`HiAnimeProvider`. Only drop to hand-rolling `keygen2`/`decryptSrc2` if you specifically
want to learn the crypto. Expect it to break on MegaCloud's next deploy — that's the nature
of the layer, and why it's behind the interface.

Self-host alternative for the boss: run `aniwatch-api` via Docker
(`ghcr.io/ghoshritesh12/aniwatch`, port 4000) and have `HiAnimeProvider` just call it.

---

## 7. Route map & caching discipline

| Route | Render | Revalidate | Note |
|---|---|---|---|
| `/` | ISR | ~1h | spotlight + trending/popular/airing/latest rails |
| `/search?q=` | dynamic | — | debounced |
| `/anime/[id]` | ISR | ~1h (`revalidateTag` when new eps air) | detail + episode grid |
| `/watch/[id]/[ep]` | **dynamic** | **NEVER cache sources** | player is a client subtree |
| `/api/sources` | route handler | **never cache** | resolve at request time |
| `/api/anime`, `/api/search` | route handler | LRU/Redis cache | metadata only |

**The rule that bites everyone:** if one route mixes a cacheable metadata fetch with the
dynamic source fetch, Next uses the **lowest** revalidate for the whole route → you lose all
caching. **Isolate source resolution** into its own route handler / client component.
**Never cache `.m3u8`/`.ts`** — they're short-lived + Referer-gated; a cached manifest is a
guaranteed-broken player minutes later.

---

## 8. Phased build (each phase ships something runnable)

### Phase 0 — Walking skeleton *(prove the pipeline, no real anime yet)*
- [ ] `apps/web` Next 15 scaffold + Tailwind
- [ ] AniList GraphQL: home rails (trending/popular/airing) + search + `/anime/[id]` detail
- [ ] `/watch/[id]/[ep]` route with Artplayer + hls.js (+ **Safari native fallback branch**)
- [ ] `services/proxy` running; play a **public test HLS** (e.g. Mux/Apple sample) *through the proxy*
- [ ] ✅ Done when: a sample stream plays in-browser via your proxy, CORS proven, catalog browsable

### Phase 1 — First real anime (allanime provider)
- [ ] `AnimeProvider` interface + `AllAnimeProvider` (search/info/episodes/servers/sources)
- [ ] `/api/sources` → provider → rewrite m3u8 through proxy → return playable URL
- [ ] Map AniList id → allanime entry (title-match; MAL-Sync where possible)
- [ ] sub/dub toggle (re-fetches sources, reloads player)
- [ ] ✅ Done when: you pick a show in the catalog and actually watch a real episode

### Phase 2 — Player UX (the visible 60% of the product)
- [ ] Quality menu from `hls.levels` (+ "Auto" = `-1`)
- [ ] WebVTT soft-subs + language selector
- [ ] Skip intro/outro: provider `intro/outro` first, **AniSkip v2** fallback (cache in localStorage)
- [ ] Multi-server auto-failover (on fatal `Hls ERROR`, try next server)
- [ ] Episode grid — **virtualized/paginated** (One Piece = 1000+ eps)
- [ ] Autoplay-next (gate behind setting; respects autoplay policy)
- [ ] Continue-watching via **localStorage** (throttled `timeupdate` ~5s; resume if <95% watched)
- [ ] Loading skeletons (hide the 1–3s source-resolution latency)

### Phase 3 — Metadata polish & mapping
- [ ] AniList as catalog source of truth: genres, relations, recommendations, schedule
- [ ] Robust AniList↔provider mapping (MAL-Sync + Dice-coefficient title match + format/year gate + AniDB episode-offset for cours)
- [ ] On-demand revalidation when new episodes air

### Phase 4 — Second provider + fallback (prove the abstraction)
- [ ] `GogoAnimeProvider` (AES-128 from page)
- [ ] Provider registry + fallback chain (allanime → gogo)
- [ ] ✅ Done when: a title missing on one provider silently resolves on another

### Phase 5 — BOSS: HiAnime / MegaCloud
- [ ] `HiAnimeProvider` wrapping pinned `aniwatch@2.27.9` (or self-hosted `aniwatch-api` Docker)
- [ ] Handle key feed (`itzzzme/megacloud-keys`), `encrypted:false` branch, `megaplay.buzz` fallback
- [ ] Normalize aniwatch schema → your `Sources` type (it differs from consumet: `tracks` vs `subtitles`, has `outro`)
- [ ] Redis cache for resolved sources (short TTL) + servers
- [ ] (Optional/learning) hand-port `keygen2`/`decryptSrc2` v3 cipher
- [ ] ✅ Done when: hianime plays through the *same* UI as allanime

### Phase 6 — Hardening
- [ ] LRU→Redis caching everywhere (metadata), strict never-cache on streams
- [ ] Graceful errors + server fallback UX, PWA (optional), Dockerized local run
- [ ] Health checks on providers (they break — detect and route around)

---

## 9. Hard parts & how to de-risk

| Hard part | Risk | De-risk |
|---|---|---|
| MegaCloud crypto | Breaks ~quarterly; v3 is a custom cipher, not AES | Wrap pinned `aniwatch` npm; isolate behind interface; ship `megaplay.buzz` fallback; **do it last** |
| ID mapping (AniList↔provider) | Wrong match = wrong episodes | MAL-Sync first, then fuzzy title-match with format+year gate; manual override table for edge cases |
| Proxy bandwidth | Cost cliff at scale | Local = free; CF Worker / cheap-egress host for deploy; never serverless for segments |
| Cloudflare anti-bot on scrapers | Scraper gets 403'd | allanime is light; for hianime use full browser headers, consider FlareSolverr if needed |
| iOS playback | Totally broken without native branch | The `canPlayType('application/vnd.apple.mpegurl')` fallback is mandatory |
| Caching a stream URL | Player breaks minutes later | Never cache `.m3u8`/`.ts`; isolate dynamic source route |

---

## 10. What to deliberately NOT build first

Skip until v1 is watchable end-to-end: **accounts/auth**, **any database** (localStorage covers
continue-watching), **monetization/ads**, **your own from-scratch scraper for the boss host**
(use the npm lib), **a custom player from scratch** (use Artplayer), **SEO/SSR tuning**,
**comments/social**, **mobile apps**, **cross-device sync**. Every one of these is a trap that
delays the only thing that matters early: *bytes on screen through your own pipeline*.

---

## 11. External dependencies & their fragility (know what can vanish)

- `aniwatch` (npm) — **live on npm**, repo DMCA-451'd. Pin `2.27.9`, vendor it.
- `itzzzme/megacloud-keys/key.txt` — **live** (v2 hex key). `yogesh-hacker` v3 feed — **gone (451)**.
- `api.aniskip.com` — **live, stable, independent** → lean on it.
- AniList GraphQL — **live, legit**, ~30 req/min (degraded), commercial license >$150/mo.
- `api.malsync.moe` — mapping, generally live.
- Hosted consumet/aniwatch APIs (`api.consumet.org`) — **down/unreliable; self-host**.

---

## 12. First action when we start coding

Phase 0, in order: scaffold `apps/web` → AniList home+search+detail → `/watch` with
Artplayer+hls.js+Safari fallback → stand up `services/proxy` → play a public test HLS through
it. That gives a browsable catalog and a proven playback pipeline before any radioactive code.

> When you're ready: say **"start Phase 0"** and I'll scaffold the Next app + proxy and get a
> test stream playing. We build the easy provider (Phase 1) right after, so you're watching real
> anime within the first couple of sessions, and we save MegaCloud for last.
