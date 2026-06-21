I'll write the implementation blueprint based on the verified research digest. This is a writing task that synthesizes the provided digest, so I'll produce the Markdown directly.

# Building an Anime Streaming Platform: Architecture & Build Plan

> Audience: a developer comfortable with Next.js/React and a Node or Python backend who wants to ship a HiAnime-shaped product (fast catalog browse, AniList-rich detail pages, episode grids, in-page HLS player, watch tracking) **without inheriting the legal and operational disaster that killed the zoro.to → aniwatch.to → hianime.to lineage** (offline March 2026, ACE/USTR pressure, GitHub 451-blocking the entire scraper ecosystem).

The single most important framing in this whole document: **the legally fatal part of HiAnime was the content layer, not the UX layer.** The browse/search/recommend/player UX is legally neutral and 100% reusable. The thing that made HiAnime infringing — scraping licensed episodes, decrypting MegaCloud, and re-serving studio HLS through a proxy — is exactly the part you replace. Everything below is built around that pivot.

---

## 1. High-Level Architecture & Content-Sourcing Stance

### 1.1 The content-sourcing decision (read this first)

You have four real options. Three are defensible; one is the HiAnime model and is off the table.

| Option | What it is | Legal posture | Indie feasibility | Verdict |
|---|---|---|---|---|
| **A. Self-host / BYO files** (Jellyfin/Plex shape) | You ship *software*; the user points it at files they legally own. Only the user reproduces/streams, privately, to themselves. No public performance, no operator-hosted catalog. | Lowest practical risk. | High. | **Recommended core** |
| **B. Aggregator of *legal* free sources** | Index & embed officially-uploaded free anime: licensor YouTube (Muse Asia, Ani-One), FAST channels (Crunchyroll Channel on Pluto/Roku/Samsung, RetroCrush), Tubi, genuine public domain. Official embeds only, respect geo-locks, never re-host. | Low, if you only link/embed *authorized* sources. | Medium. | **Recommended complement** |
| **C. Metadata / tracker / discovery** (AniList shape) | The full browse/search/recommend/track UX with **no video**. "Where to watch" deep-links to legal services (JustWatch-style). | Very low (you reproduce facts + small cover art, not works). | High. | **Build this first regardless** |
| **D. License content** | Become a real licensee via production committees. | Lowest legal risk, but economics rarely close. | Near-zero for a solo dev (catalog/library packages ~$5K–$50K/series is the only door). | Aspirational only |
| ~~**E. Scrape + extract + proxy pirate streams**~~ (HiAnime/consumet/aniwatch) | Scrape licensed anime, decrypt MegaCloud, proxy m3u8/TS. | **Direct infringement + (US) felony under the Protecting Lawful Streaming Act of 2020.** Server-side m3u8 proxying of licensed content is itself a reproduction/transmission that destroys any "we just link" defense. Ad monetization supplies the "commercial / financial benefit" element. | N/A | **Do not build.** This is what was DMCA'd and shut down. |

**My recommendation: build C + A, with B as the in-app "watch now" path.**

Concretely: ship a **metadata/discovery/tracker app (C)** as the product surface — this is AniList's own architecture, running on AniList's own public API. Layer in **legal "where to watch" deep links and official embeds (B)**. Then offer the killer feature for power users: **point the app at the user's own Jellyfin server (A)**, so the in-browser HLS player UX works end-to-end, legally, against the user's own files. You get the entire HiAnime feel — episode grid, in-page player, resume, sub/dub toggle — with the legal exposure removed.

This is also why the digest's "provider/extractor/proxy" architecture is *still worth understanding in detail*: you will build the **identical shape** (catalog → resolve source → extractor → m3u8/CORS proxy → hls.js player), but the "source" is a Jellyfin HLS URL or a YouTube/FAST embed instead of a decrypted MegaCloud blob. The proxy stops being a CORS/Referer-spoofing piracy tool and becomes a thin, legitimate gateway to your own/licensed origins (or disappears entirely when you embed YouTube/FAST).

### 1.2 Architecture diagram (text)

```
                          ┌─────────────────────────────────────────────┐
                          │                BROWSER (client)               │
                          │  Next.js App Router · React Server Components  │
                          │  hls.js + Artplayer/Vidstack player           │
                          │  Zustand/React Query · watch-progress sync    │
                          └───────────────┬───────────────────────────────┘
                                          │ HTTPS (your domain, behind a CDN)
                          ┌───────────────▼───────────────────────────────┐
                          │            EDGE / CDN (Cloudflare)             │
                          │  caches catalog JSON + rehosted cover art      │
                          └───────────────┬───────────────────────────────┘
                                          │
          ┌───────────────────────────────┼───────────────────────────────────┐
          │                               │                                   │
┌─────────▼──────────┐        ┌───────────▼────────────┐         ┌────────────▼───────────┐
│  CATALOG SERVICE   │        │  SOURCE-RESOLVER SVC    │         │   USER / TRACKER SVC    │
│  (Node/TS or Py)   │        │  ("where to watch")     │         │  auth, watchlist,       │
│                    │        │                         │         │  watch-history, scores  │
│  AniList GraphQL ──┼─┐      │  - JustWatch-style      │         │  AniList OAuth2 sync     │
│  Jikan (MAL) ──────┤ │      │    availability map     │         └────────────┬───────────┘
│  Kitsu/TMDB (art) ─┘ │      │  - Jellyfin connector   │                      │
│                      │      │    (user's own server)  │                ┌─────▼─────┐
│  ┌────────────────┐  │      │  - YouTube/FAST embed   │                │ Postgres  │
│  │ Redis cache    │◄─┘      │    resolver (legal)     │                │ (users,   │
│  │ (30 req/min!)  │         └───────────┬─────────────┘                │  history) │
│  └───────┬────────┘                     │                              └───────────┘
│          │                              │ (only if you ever serve self-hosted HLS)
│  ┌───────▼────────┐          ┌──────────▼──────────────┐
│  │ Postgres       │          │  m3u8 / CORS PROXY      │  ◄── thin, allowlisted,
│  │ (catalog,      │          │  (Cloudflare Worker or  │      points ONLY at your
│  │  mappings)     │          │   small Go/Node svc)    │      own/licensed origins
│  └────────────────┘          └─────────────────────────┘
└──────────────────────────────────────────────────────────────────────────────────────┘
                                          │
                          ┌───────────────▼───────────────┐
                          │  CONTENT ORIGIN(S)             │
                          │  A) user's Jellyfin server     │
                          │  B) YouTube IFrame / FAST CDN  │
                          │  D) your licensed HLS on a CDN  │
                          └────────────────────────────────┘
```

Key property: the **catalog service** and **user/tracker service** are the heart of the product and are identical regardless of which content route you pick. The **source-resolver** is where the legal/illegal fork lives — keep it a clean, swappable interface (`resolveSources(animeId, episode, {category}) → {sources[], subtitles[], headers?}`) so the rest of the app never knows or cares whether the bytes came from Jellyfin, YouTube, or a licensed CDN.

---

## 2. Concrete Tech Stack (per layer, with named libraries)

### 2.1 Catalog layer (the universe of "what exists")

- **Primary source: AniList GraphQL** (`https://graphql.anilist.co`). Single POST endpoint, no auth for public reads. One query type drives everything:
  - `Page(page, perPage){ media(sort: TRENDING_DESC, type: ANIME){ id idMal title{romaji english native} coverImage{large} bannerImage genres episodes status season seasonYear nextAiringEpisode{airingAt timeUntilAiring episode} } }`
  - Home rows = `sort: TRENDING_DESC` (trending), `sort: POPULARITY_DESC` (popular), `nextAiringEpisode` (airing/schedule).
  - Detail page = `Media(id: …){ … relations{edges{relationType node{id}}} recommendations externalLinks streamingEpisodes }`.
- **Secondary / fallback: Jikan v4** (`https://api.jikan.moe/v4`) for MAL ids/scores, `/seasons/now`, `/schedules`. No key; MongoDB-backed stale-while-revalidate cache (data can be up to 24h old).
- **Art enrichment: TMDB** (high-quality fanart/backdrops AniList lacks) and **Kitsu** (`application/vnd.api+json`) as a supplementary poster/synopsis fallback.
- **Schedule: AnimeSchedule.net API v3** (`/api/v3/timetables/{airType}` where `airType=raw|sub|dub|all`) for countdown rows — **note: now requires an OAuth2/PKCE Bearer app token**, no longer anonymous. AniList's `nextAiringEpisode` is the free fallback.
- **Static ID-mapping dataset: `Fribb/anime-lists`** (`anime-list-full.json`, keyed on `anidb_id`, merging `mal_id`/`anilist_id`/`kitsu_id`/`tvdb_id`/`themoviedb_id`/`imdb_id` + season info + **episode offsets**). This is how you align an AniList "Season 2" onto a continuous provider/library episode numbering. Ship the `indices/` folder for O(1) lookup.
- **Caching is mandatory, not optional:** **Redis**, ~1h TTL for catalog rows, up to 24h for Jikan. Backed by **Postgres** (or SQLite for a tiny deploy). **AniList's rate limit is degraded to 30 req/min (nominal 90), returns 429 + ~1 min `Retry-After` on exceed** — design for 30/min and cache aggressively.

> **Implementation libraries:** `graphql-request` (lightweight AniList client), `@jikan/…` or plain `fetch`, `ioredis`, Prisma or Drizzle ORM for Postgres. In Python: `httpx` + `gql` + `redis-py` + SQLAlchemy.

### 2.2 Source-resolver / "extractor-aggregator" service

This is the legitimate replacement for consumet/aniwatch's extractor tier. **Same interface, legal sources.** Reference the digest's pipeline shape (search → info → episode list → servers → resolve → assemble `ISource`) but plug in:

- **`A` Jellyfin connector:** talk to the user's Jellyfin server via its REST API (`/Items`, `/Videos/{id}/master.m3u8` with `PlaySessionId` + device/user auth). Enrich anime metadata in *their* library with **Shokofin** (Shoko Server) or the split Jellyfin plugins (`jellyfin-plugin-anilist`, `-anidb`, `-anisearch`, `-kitsu`); sync progress with **MyAnimeSync**. The connector returns a normalized `{sources:[{url, isM3U8, quality}], subtitles:[…], headers}` — exactly the `consumet` ISource shape, so your player code is unchanged.
- **`B` Legal-embed resolver:** map an AniList id → official source via a JustWatch-style availability table you maintain (seed from `externalLinks` in the AniList `Media` query). Output is either a **YouTube IFrame Player API** embed (Muse Asia / Ani-One — *geo-aware*, region-locked to SEA/India/ME) or a FAST/AVOD partner embed (Crunchyroll Channel, RetroCrush, Tubi, Pluto). No proxy, no extraction.
- **`D` Licensed-HLS resolver** (if you ever license): your own signed HLS URLs on a CDN.

**Architecture pattern to copy (legally):** the `consumet.ts` *provider-per-source* abstraction and the **`aniwatch-api` REST shape** are genuinely good API ergonomics. Mirror the route surface (`/sources?id=…&category=sub`) but with legitimate backends. Use these as **reference reading only** — note the GitHub repos are 451-blocked (DMCA); the npm dist (`@consumet/extensions@1.8.8`, `aniwatch@2.27.9`) survives if you want to study the data contracts, but **do not ship their pirate extractors**.

> **Libraries:** Node/TS with `axios`/`undici` + `cheerio` (only if you scrape *your own* Jellyfin HTML, which you won't — use its JSON API), `@jellyfin/sdk`. Express or **Hono** for the REST wrapper (Hono if you want to deploy to edge/Workers).

### 2.3 m3u8 / CORS / segment proxy layer

You only need this for route **A/D** (self-hosted or licensed HLS that's Referer/CORS-gated). For route **B** (YouTube/FAST embeds) you don't need it at all. When you do need it, build the proxy described in the digest **but pointed exclusively at your own origins**, which removes the SSRF/open-relay and anti-bot problems entirely:

- **Reference implementation: `shafat-96/go-proxy`** — the most complete concrete reference. `/proxy` (playlist) + `/ts-proxy` (segment, Range-aware). `rewritePlaylist()` resolves relative URIs and rewrites `EXT-X-STREAM-INF` / `EXTINF` / `EXT-X-KEY` / `EXT-X-MAP` / `EXT-X-MEDIA`; `GenerateHeadersForDomain()` injects per-domain headers; `withCORS()` honors a `WHITELIST_DOMAINS` allowlist.
- **TS/Node alternative: `Eltik/M3U8-Proxy`** (wraps Rob Wu's `cors-anywhere`, adds `/m3u8-proxy?url=&headers=`, AES-128 key URI support).
- **Edge variant: `MHSanaei/HLS-Proxy-Worker`** or **`Rawknee-69/Hianime-proxy`** (Hono Cloudflare Worker, `/fetch?url=&ref=`).

**Non-negotiables (the digest's hard-won gotchas):**
1. Resolve relative segment/key URIs against the **variant playlist's own base URL**, not the master's (this is the #1 bug).
2. **Thread upstream headers transitively** into every rewritten child URL (master → variant → segment → AES key). Forget the key request's headers and playback dies with a decrypt error.
3. **Stream, don't buffer** — `io.Copy` / pass `response.body`; forward the client `Range` header and return upstream `206` + `Content-Range`/`Accept-Ranges`.
4. Stamp `Access-Control-Allow-Origin` + expose `Content-Length, Content-Range, Accept-Ranges, Content-Type`; answer `OPTIONS` with `204`.
5. **Lock it down with `WHITELIST_DOMAINS`** so it's never an open relay. Since your origins are your own, you can hardcode them and HMAC-sign proxy URLs.
6. Don't blindly forward `cf-*` / hop-by-hop headers (`Connection`, `Transfer-Encoding`).

> Because you control the origin, you **skip** the entire JA3/JA4 TLS-fingerprinting, `curl-impersonate`, FlareSolverr, rotating-key nightmare that broke every pirate scraper. That whole anti-bot tier (Section "Infrastructure/anti-bot" in the digest) simply does not exist in a legitimate build.

### 2.4 Player

- **`hls.js`** for HLS playback via MSE (Safari can use native HLS as a fallback).
- **Player UI: Vidstack** (`@vidstack/react`, modern, headless-friendly, great React/Next integration, built-in `hls.js` provider) **or Artplayer** (`artplayer` + `artplayer-plugin-hls-control`, batteries-included with the "anime player" feel — skip-intro buttons, sub/dub menus). **Recommendation: Vidstack** for a React-first Next.js app; Artplayer if you want the closest visual match to HiAnime's player out of the box.
- **Subtitles:** WebVTT `<track>` text tracks; if served from a gated origin, route `.vtt` through the same proxy with `Content-Type: text/vtt` + CORS.
- **Skip intro/outro:** the `intro:{start,end}` / `outro` fields exist in the consumet ISource shape — for self-hosted you'll compute or omit these; AniList won't give them.

### 2.5 Frontend

- **Next.js (App Router)** with React Server Components for catalog pages (great for SEO + caching AniList responses server-side, keeping you under the 30 req/min limit).
- **Data: TanStack Query** (client interactivity) + RSC `fetch` with Next's cache for server-rendered rows.
- **State: Zustand** for player + watch-progress UI state.
- **Styling: Tailwind CSS** + a component kit (shadcn/ui or Radix).
- **Auth: NextAuth/Auth.js** with an AniList OAuth2 provider for list sync.
- **Image handling:** **rehost/cache cover & banner art** — AniList/Kitsu art is hotlinked from `s4.anilist.co` and will break / breach ToS. Pull through `next/image` with a caching loader or copy to your own CDN/R2 on first fetch.

---

## 3. Data Model

Normalize the catalog around AniList ids, keep mappings separate, and keep watch-history per-user. (Drizzle/Prisma-flavored sketch.)

```
anime
─────
  id              PK
  anilist_id      int  unique  (canonical key everywhere)
  mal_id          int  null
  anidb_id        int  null     (merge key for Fribb/anime-lists offsets)
  title_romaji    text
  title_english   text
  title_native    text
  synonyms        text[]
  description     text
  cover_url       text          (REHOSTED url, not s4.anilist.co)
  banner_url      text          (REHOSTED)
  format          enum(TV, MOVIE, OVA, ONA, SPECIAL)
  status          enum(FINISHED, RELEASING, NOT_YET_RELEASED, …)
  season          enum
  season_year     int
  episode_count   int  null
  genres          text[]
  next_airing_at  timestamptz null
  next_airing_ep  int  null
  updated_at      timestamptz

episode
───────
  id              PK
  anime_id        FK -> anime.id
  number          int           (absolute, AniList/AniDB-aligned)
  abs_number      int  null     (provider/library continuous numbering)
  title           text null
  is_filler       bool default false
  air_date        timestamptz null
  thumbnail_url   text null
  UNIQUE(anime_id, number)

source            (a playable origin for an episode)
──────
  id              PK
  episode_id      FK -> episode.id
  origin          enum(JELLYFIN, YOUTUBE, FAST, LICENSED_CDN)
  category        enum(sub, dub, raw)
  server_name     text          ('jellyfin', 'muse-asia', 'hd-1'…)
  url             text          (m3u8 / embed url / jellyfin item)
  is_m3u8         bool
  headers         jsonb null    (Referer/UA to replay upstream, if any)
  quality         text null
  region_lock     text[] null   (for geo-aware YouTube/FAST)
  expires_at      timestamptz null  (signed-URL expiry; re-resolve, don't cache stale)

subtitle
────────
  id              PK
  source_id       FK -> source.id
  lang            text
  url             text          (.vtt)
  is_default      bool

mapping           (AniList id  <->  external id / library item, the hard problem)
───────
  id              PK
  anime_id        FK -> anime.id
  target          enum(JELLYFIN_ITEM, YOUTUBE_PLAYLIST, FAST_CHANNEL, MAL, KITSU, TVDB, TMDB)
  external_id     text
  episode_offset  int default 0   (from Fribb/anime-lists; aligns season<->library numbering)
  confidence      real null       (if matched by title-similarity, store the Dice score)
  resolved_at     timestamptz
  UNIQUE(anime_id, target)

user
────
  id, email, anilist_id, display_name, created_at

watch_history
─────────────
  id            PK
  user_id       FK -> user.id
  episode_id    FK -> episode.id
  position_sec  int            (resume point)
  duration_sec  int
  completed     bool
  watched_at    timestamptz
  UNIQUE(user_id, episode_id)

watchlist
─────────
  user_id, anime_id, status enum(WATCHING, PLANNING, COMPLETED, DROPPED, PAUSED), score int null
  UNIQUE(user_id, anime_id)
```

**Notes from the digest baked in:**
- `mapping.episode_offset` exists because a single AniList "Season 2" maps onto a provider/library's continuous numbering — without AniDB offsets (Fribb), "episode N points to the wrong video."
- `source.headers` (jsonb) and `source.expires_at` exist because gated HLS URLs are signed and short-lived; **re-resolve on expiry, don't re-proxy a stale manifest.**
- `mapping.confidence` exists so that if you ever do title-similarity matching (route A against a messy library), you keep the Dice score and can flag low-confidence matches for review — the digest's >0.6 + format + year gate.

---

## 4. Route / Page Map (Next.js App Router)

```
app/
  page.tsx                          ── HOME
                                       Rows: Trending (AniList TRENDING_DESC),
                                       Popular (POPULARITY_DESC), Continue Watching
                                       (from watch_history), Airing Schedule
                                       (nextAiringEpisode), New Episodes.

  browse/page.tsx                   ── BROWSE
                                       Filters: genre, year, season, format, status.
                                       Server-side AniList Page query w/ filter args;
                                       infinite scroll via TanStack Query.

  search/page.tsx                   ── SEARCH
                                       ?q= → AniList search (+ Jikan fallback).
                                       Debounced autocomplete from a cached
                                       /api/search/suggest route.

  anime/[id]/page.tsx               ── ANIME DETAIL  (id = anilist_id)
                                       Synopsis, characters, genres, relations,
                                       recommendations, "where to watch" deep links,
                                       episode grid (with isFiller badges),
                                       add-to-watchlist / score.

  watch/[id]/[ep]/page.tsx          ── WATCH PAGE  (id = anilist_id, ep = number)
                                       hls.js + Vidstack/Artplayer, sub/dub/raw toggle,
                                       server picker, subtitle tracks, skip-intro,
                                       next/prev episode, resume from watch_history,
                                       progress autosave (debounced POST).

  profile/page.tsx                  ── USER  (watchlist, history, AniList sync status)

  schedule/page.tsx                 ── SCHEDULE  (weekly airing timetable + countdowns)

api/                                ── Route handlers (BFF)
  catalog/route.ts                  ── proxied/cached AniList rows
  search/route.ts
  search/suggest/route.ts
  sources/route.ts                  ── calls source-resolver svc → {sources, subtitles, headers}
  history/route.ts                  ── GET/POST watch progress
  proxy/[...path]/route.ts          ── (optional) thin m3u8/CORS proxy if not a separate svc
```

**URL contract mirrors the proven pirate UX** (`/anime/{id}` detail, `/watch/{id}/{ep}` player) — this is the part you're free to copy because it's pure UX.

---

## 5. MVP Scoped in Phases

### Phase 0 — Walking skeleton (prove the spine end-to-end)
- [ ] Next.js App Router app boots; Tailwind + component kit wired.
- [ ] Catalog service: one AniList GraphQL query (`Page` → `TRENDING_DESC`) behind a Redis cache (TTL 1h, design for 30 req/min).
- [ ] Home page renders a single trending row from cached data (RSC).
- [ ] One hardcoded "watch" page plays **one** known-good HLS test stream in Vidstack/hls.js (e.g. a sample `.m3u8` or your own Jellyfin item) — proves the player works.
- [ ] Postgres up with `anime` + `episode` tables; one seeded title.

### Phase 1 — Read-only catalog (the metadata/discovery product, route C)
- [ ] Home: Trending + Popular + Airing rows from AniList (all cached).
- [ ] Browse with genre/year/season/format filters.
- [ ] Search + debounced autocomplete (AniList, Jikan fallback).
- [ ] `anime/[id]` detail: synopsis, genres, relations, recommendations, episode grid (count from AniList).
- [ ] **Rehost cover/banner art** to your CDN/R2 (kill the `s4.anilist.co` hotlink).
- [ ] Schedule page from `nextAiringEpisode`.
- [ ] Persist catalog + mappings to Postgres on cache miss (so future loads are O(1)).

### Phase 2 — Users & tracking (still no video of your own)
- [ ] Auth.js with AniList OAuth2.
- [ ] Watchlist (add/remove, status, score) + sync to AniList lists.
- [ ] `watch_history` table + Continue-Watching row on home.
- [ ] Profile page.

### Phase 3 — Legal "watch now" (route B: aggregate legal sources)
- [ ] `source-resolver` service with the swappable `resolveSources()` interface.
- [ ] Build the JustWatch-style availability map (seed from AniList `externalLinks`).
- [ ] YouTube IFrame embeds for Muse Asia / Ani-One (**geo-aware**, show region notice when locked).
- [ ] FAST/AVOD deep links (Crunchyroll Channel, RetroCrush, Tubi, Pluto).
- [ ] Watch page renders an embed when a legal source exists; otherwise shows deep-link buttons. **Never embed a pirate player.**

### Phase 4 — BYO files (route A: the power-user killer feature)
- [ ] Jellyfin connector in the source-resolver (auth, `/Items`, `master.m3u8`).
- [ ] User connects their Jellyfin server in settings (URL + token).
- [ ] Match AniList id → Jellyfin item via Fribb offsets / title-similarity (store `confidence`).
- [ ] m3u8/CORS proxy (Go `shafat-96/go-proxy` shape) for gated Jellyfin HLS, `WHITELIST_DOMAINS`-locked + HMAC-signed URLs.
- [ ] Full in-app player against the user's own library: sub/dub toggle, subtitle tracks, resume, next-ep, progress autosave + AniList sync.

### Phase 5 — v1 polish
- [ ] Skip-intro/outro UI where data exists; keyboard shortcuts; quality selector.
- [ ] Episode `is_filler` badges (compute or import).
- [ ] Caching/observability: Redis hit-rate metrics, AniList 429 backoff with `Retry-After`.
- [ ] Legal hygiene: ToS, authorized-source-only linking, **no "watch free full episodes" marketing** (Grokster inducement defense), DMCA agent registered *if* you ever accept any user-contributed media.
- [ ] Image CDN + segment caching; rate-limit your own API.

---

## 6. The Hard Parts & How to De-Risk Them

1. **AniList ↔ source mapping (the core hard problem).** There is no shared id between trackers and content sources. *De-risk:* for route A, match against the **user's own** library where the universe is tiny and you can ask the user to confirm low-confidence matches; store `Fribb/anime-lists` `episode_offset` to fix season/cour boundaries; keep `confidence` and flag <0.6 Dice matches. You completely sidestep the pirate-era "MALSync key is stale / returns null for Zoro" problem because you're not mapping to pirate providers at all.

2. **Season/cour episode-number drift.** A single AniList "Season 2" maps onto continuous library numbering → episode N points to the wrong video. *De-risk:* always apply `episode_offset` from Fribb; show absolute *and* season-relative numbers in the UI; let the user correct a mismatch (which updates the mapping).

3. **AniList rate limit (degraded to 30 req/min, 429 + ~1 min lockout).** *De-risk:* Redis cache everything (1h TTL), do AniList calls **server-side only** (RSC / route handlers, never the browser), batch with the `Page` query, implement exponential backoff honoring `Retry-After`, and pre-warm popular rows on a cron. If you cross ~$150/mo revenue, **get an AniList commercial license** (email them).

4. **Gated/expiring HLS (route A/D).** Signed manifests die in minutes. *De-risk:* store `source.expires_at`; **re-resolve, don't re-proxy** stale manifests; thread headers transitively through master→variant→segment→key (the digest's #2 proxy bug); stream (never buffer) segments.

5. **Cover/banner hotlinking breakage + ToS.** *De-risk:* rehost art on first fetch to R2/your CDN; serve via `next/image`.

6. **Geo-locks on legal free sources (route B).** Muse Asia / Ani-One are region-locked to SEA/India/ME. *De-risk:* store `region_lock` on sources; detect region; show "available in your region on X / not available here" instead of bypassing (bypassing reintroduces ToS/legal risk).

7. **Reading the reference repos.** consumet.ts, aniwatch, aniwatch-api, MAL-Sync-Backup are **GitHub 451-blocked (DMCA)**; the owner also renamed `ghoshRitesh12 → ritesshg`. *De-risk:* study data contracts from the surviving **npm dist** (`@consumet/extensions@1.8.8`, `aniwatch@2.27.9`) or DeepWiki — for *API shape only*, not to ship their extractors.

---

## 7. What to Deliberately NOT Build First (or at all)

- **Do NOT build a scraper/extractor for any pirate site.** No MegaCloud/RapidCloud/VidCloud decryption, no `getSources` + CryptoJS AES, no community key-repo fetching (`itzzzme/megacloud-keys`, etc.). This is the part that got the entire ecosystem DMCA'd in March 2026 and is a US felony for a for-profit operator under the Protecting Lawful Streaming Act.
- **Do NOT build the anti-bot tier.** No JA3/JA4 spoofing (`CycleTLS`/`curl-impersonate`), no FlareSolverr, no residential-proxy rotation, no Cloudflare-challenge solving. If you're not scraping hostile sites, none of it is needed.
- **Do NOT build a general-purpose open m3u8 proxy.** Only proxy your own/licensed origins, always `WHITELIST_DOMAINS`-locked + signed — an open `?url=anything` proxy is an SSRF/open-relay/free-bandwidth liability.
- **Do NOT build popunder/redirect/malvertising monetization.** That economy (PopAds/Adsterra/PropellerAds, ~78% of pirate sites serving malware-laden ads) is exactly why the niche is radioactive and Google AdSense permanently bans pirated-anime pages. If you monetize, do it the legitimate way later (VAST + SSAI + Google Ad Manager at $5–$15+ CPM, or an SVOD no-ads tier) — and only once you have licensed content.
- **Do NOT build your own metadata DB from scratch.** Lean on AniList; don't try to out-curate it.
- **Do NOT chase licensing (route D) as an indie.** Production committees gate simulcast; sub-agents add months + 15–20% markup. Park it.
- **Don't over-engineer infra early.** Skip multi-region, microservice sprawl, and bespoke transcoding until Phase 4+. The catalog + tracker (Phases 0–2) is a complete, shippable, legal product on its own.

---

### Reference repos (from the digest) — what to actually reuse

| Repo | Use it for | Caveat |
|---|---|---|
| **AniList API** (`docs.anilist.co`, `graphql.anilist.co`) | The catalog. Reference architecture for the whole metadata/tracker product. | 30 req/min degraded; commercial license >$150/mo. |
| **`Fribb/anime-lists`** | ID mapping + episode offsets across MAL/AniList/AniDB/TVDB/TMDB. | Staleness for brand-new seasonal titles is unknown. |
| **Jikan v4** (`api.jikan.moe`) | MAL fallback, seasons, schedules. | ~60 req/min, up-to-24h stale cache. |
| **`shafat-96/go-proxy`** | Most complete m3u8/segment/key/CORS proxy reference (route A/D only). | Lock to your origins; allowlist + signed URLs. |
| **`Eltik/M3U8-Proxy`** | TS/Node proxy pattern (canonical, copied widely). | Same locking caveat. |
| **`MHSanaei/HLS-Proxy-Worker` / `Rawknee-69/Hianime-proxy`** | Cloudflare Worker edge-proxy variant. | CF ToS restricts video on its CDN/Workers — verify before relying on it. |
| **Jellyfin** + **Shokofin** / split `jellyfin-plugin-{anilist,anidb,anisearch,kitsu}` + **MyAnimeSync** | The entire route-A BYO-files backbone. | `jellyfin-plugin-anime` is archived; use the split plugins or Shokofin. |
| **`aniplaynow/airin`** | Example Next.js + AniList anime frontend to study UX patterns. | It's built on consumet/anify (pirate sources) — copy the *UI*, not the data layer. |
| **`@consumet/extensions` / `aniwatch` (npm)** | Reference *only* for API/data-contract shapes (ISource, episode-list, server/category model). | GitHub 451-blocked; **do not ship their extractors.** |

**Bottom line:** build AniList-backed catalog + tracker (Phases 0–2) as a clean, legal, shippable product; add legal embeds (Phase 3) and a Jellyfin BYO-files player (Phase 4) to deliver the full HiAnime experience — and never build the scraping/extraction/anti-bot/proxy-pirate-streams tier that defined, and ultimately destroyed, the original.