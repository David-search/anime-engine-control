# 16 · As-built: backend integration & frontend

> ⚠️ **HISTORICAL as-built snapshot (2026-06-26) — NOT the current topology.** The video
> origin has since **migrated from `vast-canada-3` to offshore (`185.255.120.59`)**, the
> build farm is now **6 nodes** (`canada-2..7`), and serving is via the **Bunny CDN**
> (`cdn.anichan.net`, token-signed) — the backend now emits direct signed CDN URLs, not
> just the proxy this doc describes. Trust this for the *design & logic*. CURRENT state:
> [STATE.md](../STATE.md) · [RUNBOOK.md](RUNBOOK.md) · [19-cdn-token-auth-and-hardening.md](19-cdn-token-auth-and-hardening.md) · CLAUDE.md.

> How the self-hosted video origin (vast-canada-3) plugs into the **live**
> AniChan site on vast-canada-2: the star **AniChan** source, the HLS proxy that
> hides the origin IP, the token-auth cache-state index, and the UI that surfaces
> coverage + episode titles + faithful (JASSUB) subtitles.
>
> Scope = the APP host. The origin pipeline (ingest/map/build) is docs 11–15;
> here we document everything *downstream* of `cache_db.register` + the
> `master.m3u8` nginx serves. Present tense, as-built.

## 0. Where the seam sits

```
                  vast-canada-3 (origin, ephemeral GPU)         vast-canada-2 (app host)
                  ─────────────────────────────────────         ────────────────────────
   user opens ep ─────────────────────────────────────────────▶ backend /watch/servers
        ▲                                                              │
        │                                                              ├─▶ trigger_ingest  ──┐
        │                                                              │   (fire-and-forget)  │
        │                                              ingest_api :35147 ◀────────────────────┘
        │                                                   │ queue → ingest.py → hls_build
        │                                                   │ → cache_db.register
        │                                                   ├─▶ POST /watch/cache-state ──▶ Mongo selfhost_cache
        │                                                   │   (token-auth, coverage+titles)   ▲
        │   master.m3u8 / seg / vtt / ass / fonts           ▼                                   │ read
        └──────── proxied by backend ◀──── nginx origin :35346                  catalog detail/cards
                  (origin IP never reaches browser)
```

Two independent data flows cross the seam:

| Flow | Direction | Transport | Auth | Purpose |
|---|---|---|---|---|
| **Probe + stream** | app → origin | HTTP GET `master.m3u8`, then proxied segments | none (read) | does the episode exist? then serve its bytes through the proxy |
| **Cache-state** | origin → app | HTTP POST `/watch/cache-state` | `X-Ingest-Token` | tell Mongo which eps are cached + their titles |
| **Ingest trigger** | app → origin | HTTP GET `/ingest` | `X-Ingest-Token` | ask the origin to cache an episode a user just opened |

The origin's `cache_db` (sqlite on the node) is the **source of truth** for what's
cached. Mongo `selfhost_cache` is a **read-index** pushed from it
([watch.py:151-174](../../backend/app/routers/watch.py#L151)) — the site reads the
index for badges/titles and never has to probe the origin to render a card.

## 1. Config — the four `SELFHOST_*` keys

[config.py:28-33](../../backend/app/config.py#L28). All optional; the whole feature
is dark when `SELFHOST_CACHE` is unset, so the app runs identically with or without
a live origin.

| Env key | Example (on-server `.env`) | Used by | Effect |
|---|---|---|---|
| `SELFHOST_CACHE` | `1` | `_selfhost_source`, `trigger_ingest` | master switch (`"1"` → on) |
| `SELFHOST_ORIGIN` | `http://159.48.242.1:35346` | `_selfhost_source` | nginx origin base; `/{aid}/{ep}/{cat}/master.m3u8` appended. `rstrip("/")` |
| `SELFHOST_INGEST_URL` | `http://159.48.242.1:35147` | `trigger_ingest` | ingest_api base for the on-open trigger |
| `SELFHOST_INGEST_TOKEN` | (shared secret) | `trigger_ingest` (send) + `cache_state` (verify) | one shared secret, used both ways |

The origin IP lives **only** in these server-side env values — it is never sent to
the browser (see §3). On the node side the mirror keys are `BACKEND_URL`
(`http://70.30.158.46:43577`) and `INGEST_TOKEN`, read by
[ingest.py:28](ingest.py#L28) / `push_cache_state`.

> ⚠️ Per [CLAUDE.md], `SELFHOST_*` lives in `/home/anime/backend/.env` on the
> server and must **never** be clobbered by a local `.env` sync.

## 2. The star AniChan source (`host="anichan"`, ranked #1)

### 2.1 Probe → source object

[`_selfhost_source`](../../backend/app/sources.py#L268) is the whole integration on
the read side. Given `(anilist_id, ep, category)`:

1. Bail immediately if `SELFHOST_CACHE`/`SELFHOST_ORIGIN` are unset
   ([sources.py:272](../../backend/app/sources.py#L272)) — zero cost when dark.
2. `GET {origin}/{aid}/{ep}/{cat}/master.m3u8` with a **5 s** timeout
   ([sources.py:276](../../backend/app/sources.py#L276)). The existence of a
   playable master *is* the cache check — no DB lookup, so a freshly-built episode
   is visible the instant nginx can serve it.
3. Validate it's really HLS: `"#EXTM3U" in r.text[:64]`
   ([sources.py:279](../../backend/app/sources.py#L279)) — a 200 that isn't a
   playlist (error page, redirect) is rejected.
4. Build the subtitle/font list (§5), then return the source dict
   ([sources.py:315-317](../../backend/app/sources.py#L315)):
   ```python
   {"host": "anichan", "type": "hls", "label": "AniChan · self-hosted (ad-free)",
    "url": f"{base}/master.m3u8", "referer": "", "subtitles": subs, "fonts": fonts, "intro": None}
   ```
   `host="anichan"` is the **stable key** the rest of the stack branches on (ranking,
   green styling, naming). `referer=""` because our own origin needs no CDN Referer.

### 2.2 Ranking #1 + concurrency

[`resolve_all`](../../backend/app/sources.py#L418) resolves the self-host probe and
the Miruro curated list **concurrently** via `asyncio.gather`, then prepends the
self-host source when present:

```python
miruro, selfhost = await asyncio.gather(_miruro_servers(...), _selfhost_cached(...))
return [selfhost, *miruro] if selfhost else miruro
```

Two design choices, both deliberate:

- **Concurrent** ⇒ the self-host probe adds **no latency** — it overlaps the (slower)
  Miruro pipe calls.
- **Separate caches** ([sources.py:348-360](../../backend/app/sources.py#L348)): the
  self-host probe has its own short TTL (**positive 60 s / negative 15 s**) in
  `_selfhost_cached`, *not* the Miruro 3-min `_servers_cache`. Why: if a just-cached
  episode were baked into the 3-min Miruro list cache, it would stay hidden for up to
  3 minutes after the build. The 15 s negative TTL means an episode that finishes
  building surfaces as Source 1 within ~15 s of the next page open.

### 2.3 The on-open ingest trigger

[`trigger_ingest`](../../backend/app/sources.py#L324) is fired fire-and-forget from
[`servers`](../../backend/app/routers/watch.py#L122) (`_bg(...)`) every time a user
opens an episode. It:

- dedups per `(anilist_id, ep)` for **30 min** (`_INGEST_TTL`) so reloads don't spam
  the node ([sources.py:332](../../backend/app/sources.py#L332));
- sends `X-Ingest-Token` and a **4 s** timeout, swallowing all errors — a down node
  never affects the page ([sources.py:337-342](../../backend/app/sources.py#L337)).

The node itself dedups vs cached/in-flight, caps concurrency, and enforces storage —
so this end stays dumb. The requested ep lands in the node's **high-priority** lane
(doc 15); only prefetch/precache go to the low lane.

## 3. The HLS proxy — hiding the origin IP

The browser must never learn the origin IP. Every playable byte is fetched
server-side by the backend and re-served from `anichan.net`. The self-host source is
**not special** here — it rides the exact same `/m3u8` · `/seg` · `/vtt` proxy that
the Miruro CDN sources use ([watch.py:202-297](../../backend/app/routers/watch.py#L202)).

### 3.1 URL rewriting (`servers` endpoint)

[`servers`](../../backend/app/routers/watch.py#L116) turns each resolved source into
proxied URLs the client can hit. For the self-host (hls) source
([watch.py:131-146](../../backend/app/routers/watch.py#L131)):

| Asset | Proxied via | Result field |
|---|---|---|
| master/variant playlist | `_proxy("m3u8", url, ref)` | `stream` |
| WebVTT subtitle | `_proxy("vtt", file, ref)` | `subtitles[].url` |
| styled ASS subtitle | `_proxy("seg", ass, ref)` | `subtitles[].ass` |
| embedded font | `_proxy("seg", font, ref)` | `fonts[]` |

`_proxy` ([watch.py:53-55](../../backend/app/routers/watch.py#L53)) emits a
**root-relative** URL: `/api/watch/m3u8?url=…&ref=…`. The client absolutizes it
against `CLIENT_BACKEND` (`https://anichan.net`) in
[api.ts getServers](../../frontend/lib/api.ts#L112) — so the only host the browser
ever sees is `anichan.net`. The origin's `159.48.242.1:35346` is encoded inside the
opaque `url=` query param, fetched **only** server-side.

### 3.2 Manifest rewrite (`/m3u8`)

[`m3u8`](../../backend/app/routers/watch.py#L202) fetches the upstream playlist and
rewrites **every** URI line to re-enter the proxy
([watch.py:213-244](../../backend/app/routers/watch.py#L213)):

- Segment/key/map byte URIs → `seg`; nested playlist URIs (`.m3u8` — audio group /
  I-frame / variant) → `m3u8`, so the recursion follows the whole HLS tree and no
  upstream URL ever leaks ([watch.py:236-241](../../backend/app/routers/watch.py#L236)).
- `EXT-X-MEDIA:TYPE=SUBTITLES` groups + their `STREAM-INF SUBTITLES=` refs are
  **stripped** ([watch.py:224-230](../../backend/app/routers/watch.py#L224)). Subs are
  delivered out-of-band as player `<track>`s / JASSUB; leaving them in-manifest would
  make hls.js add duplicate textTracks that desync the subtitle selector. (The
  master from our origin *does* carry in-manifest `EXT-X-MEDIA` subs as a fallback —
  `_selfhost_source` parses them only when `tracks.json` is absent, §5.)

### 3.3 Segment proxy (`/seg`) — Range-aware, streaming

[`seg`](../../backend/app/routers/watch.py#L247) forwards the client `Range` header
upstream and **streams** the response body back (`StreamingResponse` over
`aiter_bytes`), passing through `content-length` / `content-range` /
`accept-ranges` so seeking works ([watch.py:259-272](../../backend/app/routers/watch.py#L259)).
It carries a 1-hour `Cache-Control`. The same endpoint serves the ASS + font bytes
(they're opaque binary to the proxy).

### 3.4 SSRF guard (`_safe`)

Because the proxy fetches an **attacker-influenceable `url=`**, every proxy endpoint
calls [`_safe`](../../backend/app/routers/watch.py#L62) first
([watch.py:204](../../backend/app/routers/watch.py#L204),
[249](../../backend/app/routers/watch.py#L249),
[280](../../backend/app/routers/watch.py#L280)). It:

1. requires scheme `http`/`https` with a hostname
   ([watch.py:68](../../backend/app/routers/watch.py#L68));
2. rejects `localhost`, `*.local`, `*.internal`
   ([watch.py:73](../../backend/app/routers/watch.py#L73));
3. **resolves the host** (`getaddrinfo`) and rejects if *any* resolved address is
   private / loopback / link-local / reserved / unspecified / multicast
   ([watch.py:80-87](../../backend/app/routers/watch.py#L80)).

Resolving (not just string-matching) is what blocks octal/decimal/hex IP-literal
encodings and DNS names that point at internal IPs or the cloud-metadata endpoint
`169.254.169.254`. Passed hosts are cached **5 min** per host
([watch.py:71](../../backend/app/routers/watch.py#L71)) to keep the hot path cheap.
The self-host origin (a public IP) passes; it gets no special exemption — proving the
proxy treats our origin like any other upstream.

## 4. Cache-state — token-auth ingestion + read path

### 4.1 Write path (origin → Mongo)

After **every** build, and after eviction, the node calls
[`push_cache_state`](ingest.py#L674) → `POST /api/watch/cache-state` with
`X-Ingest-Token` and a JSON body:

```json
{ "anilist_id": 199221, "total_eps": 24,
  "cached": {"sub": [1,2,3], "dub": []},
  "ep_titles": {"1": "Future Engine", "2": "..."} }
```

The endpoint [`cache_state`](../../backend/app/routers/watch.py#L151):

1. **Auth:** rejects with 401 unless `SELFHOST_INGEST_TOKEN` is set *and*
   `x_ingest_token` matches ([watch.py:157](../../backend/app/routers/watch.py#L157)) —
   the same shared secret used to *send* the ingest trigger, here used to *verify*
   the push. Constant config, single secret.
2. Parses/validates `anilist_id` (400 on bad), requires a DB (503 if none).
3. **Upserts** `selfhost_cache` keyed by `_id = anilist_id`
   ([watch.py:167-171](../../backend/app/routers/watch.py#L167)):
   `{cached, ep_titles, total_eps, updated_at}`.

Eviction also calls `push_cache_state`, so a freed episode disappears from coverage —
the index stays in sync with the node's real disk state, never drifting stale.
The push is **best-effort** on the node (`push skipped` on error) — a down backend
never fails an ingest.

### 4.2 Read path (Mongo → site)

Two readers, both pure Mongo reads (no origin probe):

**Detail** — [`detail`](../../backend/app/routers/catalog.py#L136) reads
`selfhost_cache` for the one anime and attaches `out["selfhost"]` via
[`_selfhost_out`](../../backend/app/routers/catalog.py#L33), which shapes the doc into
what the frontend wants ([catalog.py:38-40](../../backend/app/routers/catalog.py#L38)):

```python
{"cached_eps": sorted(sub ∪ dub), "cached_sub": sub, "cached_dub": dub,
 "count": len(eps), "total_eps": …, "ep_titles": …}
```

`cached_eps` is the **union** of sub+dub episode numbers — the set of eps for which we
host *something*, which is what drives the green episode markers.

**Cards** — [`_enrich_cards`](../../backend/app/routers/catalog.py#L43) is called by
**every** list endpoint (trending/popular/airing/browse/search). It does **one
batched** `selfhost_cache.find({_id: {$in: ids}})` for the whole page, then stamps a
minimal `{count, total_eps}` onto each card that has coverage
([catalog.py:51-61](../../backend/app/routers/catalog.py#L51)). Batched = one query
per page regardless of card count; a no-op when nothing is self-hosted, so the cost
is ~zero until the origin starts pushing.

The shapes are typed in [types.ts](../../frontend/lib/types.ts#L7): full
`SelfHostMeta` (`cached_eps`/`count`/`total_eps`/`ep_titles`) on `Anime`, the lean
`{count, total_eps}` on `Card`.

## 5. Faithful subtitles — JASSUB with WebVTT fallback

Anime subs are styled `.ass` (karaoke, signs, positioning). ASS→WebVTT loses *all*
styling. So the origin's `hls_build` ships **styled ASS + embedded fonts + a
`subs/tracks.json` manifest**, and the player renders ASS faithfully via JASSUB
(libass-wasm), falling back to WebVTT only if JASSUB can't load. Styling is a pure
upgrade with **no regression**.

### 5.1 Backend: expose ASS + fonts (proxied)

`_selfhost_source` prefers `subs/tracks.json`
([sources.py:294-302](../../backend/app/sources.py#L294)): for each track it emits
both a `vtt` URL (fallback) and an `ass` URL, plus the `fonts[]` list. If the
manifest is missing it falls back to parsing the master's `EXT-X-MEDIA:SUBTITLES`
lines for VTT-only tracks ([sources.py:305-314](../../backend/app/sources.py#L305)).
`_add` ([sources.py:285](../../backend/app/sources.py#L285)) builds a readable label
via [`_sub_label`](../../backend/app/sources.py#L251) (language name + a region hint
parsed out of the track NAME, dropping fansub/source tags) and de-dups colliding
labels with a `(2)` suffix.

`servers` then proxies ASS + fonts through `/seg` (binary) and VTT through `/vtt`
([watch.py:139-145](../../backend/app/routers/watch.py#L139)), so the client gets
`anichan.net`-relative URLs for all three.

### 5.2 Frontend: JASSUB render, VTT fallback

[Player.tsx](../../frontend/components/Player.tsx). The decision is one line
([Player.tsx:47](../../frontend/components/Player.tsx#L47)):

```ts
const useJassub = fonts.length > 0 && subtitles.some((s) => s.ass);
```

| Condition | Renderer |
|---|---|
| `fonts[]` present **and** a track has `ass` | JASSUB (libass-wasm) over the `<video>` |
| otherwise | native WebVTT `<track>` (built from `s.url`) |
| JASSUB import/init throws | falls back to WebVTT (`jassubOk` stays false) |

Mechanics:

- JASSUB is **dynamically imported** ([Player.tsx:76](../../frontend/components/Player.tsx#L76))
  so the wasm bundle only loads when an ASS source is actually selected. It's
  constructed with the selected `ass` subUrl, the proxied `fonts`, and the
  worker/wasm staged at `/jassub/jassub-worker.{js,wasm}`
  ([Player.tsx:78-83](../../frontend/components/Player.tsx#L78)). Those static assets
  are `COPY public`-ed into the image at build (Dockerfile).
- The native-VTT effect explicitly **disables** the WebVTT track while JASSUB is
  rendering (`showVtt = !useJassub || !jassubOk`,
  [Player.tsx:59-63](../../frontend/components/Player.tsx#L59)) — so you never get
  double subtitles, and if JASSUB fails (`jassubOk=false`) the VTT track is shown
  instead. On a JASSUB error the catch just `console.warn`s and leaves WebVTT live
  ([Player.tsx:85-87](../../frontend/components/Player.tsx#L85)).
- The subtitle `<select>` ([Player.tsx:173-183](../../frontend/components/Player.tsx#L173))
  drives a single `subIdx`; both renderers read it, so the one picker controls
  whichever path is active. `CC: Off` = index -1.

The Miruro CDN sources have `ass`/`fonts` empty, so they naturally render as WebVTT —
JASSUB is an AniChan-source upgrade, the same component for both.

## 6. Source naming — ★ AniChan + Source 1..N

The backend names everything `source1..sourceN` positionally
([watch.py:127](../../backend/app/routers/watch.py#L127)) — `name` is just a stable
key. The **human label** is computed on the client so the star source is *named*, not
*numbered*, and the numeric sources stay 1..N with no confusing gap.

[WatchPanel.tsx:75-81](../../frontend/components/WatchPanel.tsx#L75):

```ts
const genericNum = (i) => servers.slice(0, i).filter((x) => x.host !== "anichan").length + 1;
const sourceLabel = (s, i) => (s.host === "anichan" ? "★ AniChan" : `Source ${genericNum(i)}`);
```

`genericNum` counts only the **non-anichan** sources before position `i`, so with
the AniChan source pinned at index 0 the bar reads:

```
Sources   [★ AniChan]  [Source 1]  [Source 2]  [Source 3 ⧉] …
```

i.e. AniChan is named, and the first Miruro source is "Source 1" (not "Source 2") —
no gap where a numeric "Source 1" would have been. Embeds get a `⧉` suffix
([WatchPanel.tsx:139](../../frontend/components/WatchPanel.tsx#L139)). Failure notices
reuse the same naming via `srcLabel`
([WatchPanel.tsx:77-81](../../frontend/components/WatchPanel.tsx#L77)).

## 7. UI — coverage, titles, markers

### 7.1 WatchPanel

[WatchPanel.tsx](../../frontend/components/WatchPanel.tsx) receives `epTitles` +
`cachedEps` (from the detail page's `selfhost`). It renders:

| Element | Source | Code |
|---|---|---|
| **Episode title** in the header (`Episode N: title`) | `epTitles[ep]` | [WatchPanel.tsx:122](../../frontend/components/WatchPanel.tsx#L122) |
| **Green-bordered ★ AniChan button**, ranked first | `host === "anichan"` styling | [WatchPanel.tsx:131-134](../../frontend/components/WatchPanel.tsx#L131) |
| **Green marker** on cached episodes (inset bottom border `#34d399`) | `cachedSet.has(n)` | [WatchPanel.tsx:169](../../frontend/components/WatchPanel.tsx#L169) |
| **Per-episode tooltip** (`Episode N · title · ★ self-hosted`) | `epTitles` + `cachedSet` | [WatchPanel.tsx:170](../../frontend/components/WatchPanel.tsx#L170) |

`cachedSet` is a `Set(cachedEps)` ([WatchPanel.tsx:69](../../frontend/components/WatchPanel.tsx#L69))
so the per-episode lookup in the strip is O(1). The player is fed the active source's
`subtitles`, `fonts`, and `intro` ([WatchPanel.tsx:104-106](../../frontend/components/WatchPanel.tsx#L104)),
and auto-skips a dead source to the next working one
([WatchPanel.tsx:84-94](../../frontend/components/WatchPanel.tsx#L84)) — surfacing
*which* source failed by its display name, never a silent black screen.

### 7.2 AnimeCard coverage badge

[AnimeCard.tsx:32-37](../../frontend/components/AnimeCard.tsx#L32): when
`anime.selfhost?.count` is truthy, a green badge `★ count/total` renders alongside
SUB/DUB:

```tsx
<span className="bdg" style={{ background:"#34d399", color:"#06281d", fontWeight:700 }}
  title="Self-hosted on AniChan — ad-free HD">
  ★ {anime.selfhost.count}{anime.selfhost.total_eps ? `/${anime.selfhost.total_eps}` : ""}
</span>
```

This `count`/`total_eps` is exactly the minimal pair `_enrich_cards` stamps (§4.2),
so a card shows "★ 3/24" with one batched Mongo read and no origin contact.

## 8. End-to-end, one episode open

```
1. User opens anime #199221, ep 1, sub.
2. GET /api/watch/servers?anilistId=199221&ep=1&category=sub          [watch.py:116]
   ├─ _bg(trigger_ingest)  ── (token) ─▶ node /ingest  (hi-lane cache, 30-min dedup)
   └─ resolve_all:  gather(_miruro_servers, _selfhost_cached)         [sources.py:418]
        _selfhost_cached → _selfhost_source:
          GET {origin}/199221/1/sub/master.m3u8  (5s)  → #EXTM3U ✓    [sources.py:276]
          GET {origin}/199221/1/sub/subs/tracks.json → ass+vtt+fonts  [sources.py:294]
3. Response: servers=[ {host:anichan, source1, stream:/api/watch/m3u8?url=…,
                         subtitles:[{url:/vtt…, ass:/seg…}], fonts:[/seg…]},
                        {host:animedao, source2, …}, … ]              [watch.py:124]
4. Browser plays /api/watch/m3u8?url=<origin master> :
     backend _safe(url) → fetch → rewrite every URI to /seg|/m3u8     [watch.py:202]
     segments stream through /seg (Range)                              [watch.py:247]
   Browser only ever talks to anichan.net — origin IP hidden.
5. UI: ★ AniChan pinned #1 (green), header "Episode 1: Future Engine",
       ep-1 chip has the green marker, JASSUB renders the styled .ass.
6. (later) node finishes building ep 2 → push_cache_state →
   selfhost_cache._id=199221 cached.sub=[1,2] → detail/cards show ★ 2/24.
```

## 9. Why it's built this way (rationale recap)

| Decision | Why |
|---|---|
| `host="anichan"` as the branch key | provider/source numbers rotate; the host string is stable across ranking, styling, naming |
| Probe `master.m3u8`, not Mongo, on the watch path | the playable artifact *is* the truth; zero staleness, freshly-built ep is instantly playable |
| Separate 60/15 s self-host cache | a just-built ep must not hide behind the 3-min Miruro list TTL |
| `gather` Miruro + self-host | the probe adds no latency to the page |
| Same proxy as Miruro for our own bytes | one code path; origin IP hidden uniformly; SSRF guard covers it for free |
| `_safe` resolves hostnames | string checks miss octal/hex IP-literals + DNS-to-internal; resolving blocks metadata-IP SSRF |
| Mongo `selfhost_cache` as a read-index | catalog renders badges/titles without ever probing the (ephemeral) origin |
| Token both ways (trigger + cache-state) | one shared secret; the node↔app channel is the only privileged surface |
| JASSUB with VTT fallback | faithful ASS styling, but a pure upgrade — VTT still works if wasm can't load |
| Named ★ AniChan, numbered Source 1..N | star is *the* differentiator; numeric list stays gap-free and legible |
