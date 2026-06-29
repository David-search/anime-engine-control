# 15 · As-built: ingest automation, cache & serving

> ⚠️ **HISTORICAL as-built snapshot (2026-06-26) — NOT the current topology.** The video
> origin has since **migrated from `vast-canada-3` (`159.48.242.1`) to offshore
> (`185.255.120.59`)**, the build farm is now **6 nodes** (`canada-2..7`), and serving is
> via the **Bunny CDN** (`cdn.anichan.net`, token-signed). Trust this doc for the *design
> & logic*, NOT for hosts/IPs/ports. CURRENT state: [STATE.md](../STATE.md) ·
> [RUNBOOK.md](RUNBOOK.md) · [19-cdn-token-auth-and-hardening.md](19-cdn-token-auth-and-hardening.md) · CLAUDE.md.

The automation + storage tier that turns **"a viewer just opened episode N"**
into **"a static HLS package nginx serves to everyone"** — and keeps doing it
within a fixed GB budget, without ever letting a bulk pre-cache backlog starve a
real viewer. This documents the layer *as it actually runs* on the video origin
(`vast-canada-3`, `/data/`): the on-open trigger, the two-lane priority queue,
the SQLite cache index + LRU eviction, how a build registers and pushes
cache-state back to the backend, and the nginx static serving.

> Scope: the **video-origin** node only. Mapping/discovery/selection internals
> (the "torrent → *correct* episode" problem) are doc
> [11](11-ingest-automation.md) + [13](13-mapping-rethink.md); HLS layout +
> measured throughput is doc [10](10-pipeline-prototype-measured.md); *why*
> pre-cache is the biggest cold-start lever is doc
> [12](12-cold-start-and-instant-playback.md). This doc is the **plumbing that
> wires them together**.

## The two hosts (where each piece runs)

| Host | Role | Runs |
|------|------|------|
| **vast-canada-2** (`70.30.158.46`) | APP host | `anime-frontend` (Next.js, domain `anichan.net`), `anime-backend` (FastAPI, public `:43577`), shared `mongodb` + `elasticsearch` |
| **vast-canada-3** (`159.48.242.1`, EPHEMERAL RTX-4070) | **VIDEO ORIGIN** | `ingest_api.py` (public `:35147`), `ingest.py`/`hls_build.py`/`cache_db.py`/`precache.py`, transmission, **nginx** serving `/data/cache` (public `:35346`) |

The backend **never** touches video bytes and the origin IP **never** reaches
the browser — every stream is proxied through `anichan.net/api/watch/...`
(see [§ Serving](#serving--static-hls-at-rest-over-nginx)). The origin node is
ephemeral by design: storage is rebuildable, so losing it costs only re-ingest
time.

## End-to-end flow (one diagram)

```
USER opens anime page (anichan.net)
  │
  ▼ GET /watch/servers
BACKEND (vast-canada-2)  ──fire-and-forget──►  trigger_ingest
  │  (also returns Miruro source instantly, so the user never waits)
  ▼ GET http://159.48.242.1:35147/ingest?anilist_id=N&ep=E   X-Ingest-Token
INGEST_API (vast-canada-3, :8001)  ── enqueue() ──►  two-lane queue
  │                                                   _hi (on-demand)   ← ep E
  │                                                   _lo (prefetch)    ← E+1..
  ▼ worker pool drains _hi before _lo
ingest.py episode N E
  │  map_anidb (ani.zip→AniDB, cached)  →  find_releases  →  select_release
  ▼ transmission download (or per-file batch extract)
hls_build.py  (remux H.264 master + NVENC 720/480 ladder + ALL subs/audio + fonts)
  │
  ├─►  cache_db.register   (SQLite index row, bytes, renditions, langs)
  ├─►  ingest.py evict CAP_GB   (LRU-trim to the byte budget)
  └─►  push_cache_state → BACKEND POST /api/watch/cache-state  (coverage + ep titles)
  ▼
nginx serves /data/cache/{N}/{E}/sub/master.m3u8  ── proxied by backend ──►  ★ AniChan (Source 1)
```

The user is **never** blocked on this pipeline: `/watch/servers` returns the
Miruro cover immediately and fires the ingest trigger as a background task.
A cold open plays via Miruro while the static package builds; the *next* open
of that episode is served from `/data/cache` as **★ AniChan**.

---

## The on-open trigger → ingest_api

`ingest_api.py` is a single-file `ThreadingHTTPServer` on `:8001`
([ingest_api.py:135](ingest_api.py#L135)), vast-mapped to public `:35147`,
launched by `/data/run_ingest_api.sh` inside a tmux session `ingestapi` so it
survives SSH disconnects. It is deliberately **not** a public download button:

| Guardrail | Where | Why |
|-----------|-------|-----|
| Shared-secret auth | [ingest_api.py:92](ingest_api.py#L92) — `X-Ingest-Token` must equal `INGEST_TOKEN` (`== backend SELFHOST_INGEST_TOKEN`) | a public `/ingest?anilist_id=…` would be a free transcode-and-store DoS |
| Two bounded lanes | [ingest_api.py:34-35](ingest_api.py#L34) — `_hi` (cap `HI_MAX=50`), `_lo` (cap `QUEUE_MAX=60`) | back-pressure: a saturated lane *rejects* rather than growing without bound |
| Dedup vs in-flight + cached | [ingest_api.py:72-84](ingest_api.py#L72) | the same episode opened by 10 viewers enqueues **once** |
| Time-bounded subprocesses | [ingest_api.py:51](ingest_api.py#L51) build `timeout=5400`s, [ingest_api.py:54](ingest_api.py#L54) evict `timeout=600`s | a stuck torrent/ffmpeg can't wedge a worker forever |
| Fixed worker pool | [ingest_api.py:131-132](ingest_api.py#L131) — `MAX_CONC=2` daemon threads | bounded GPU/disk concurrency on the origin |

### Endpoints

| Endpoint | Handler | Effect |
|----------|---------|--------|
| `GET /ingest?anilist_id&ep[&precache=1]` | [ingest_api.py:98](ingest_api.py#L98) | `enqueue()` the ep + prefetch; returns `{started, warmed, inflight}` |
| `GET /touch?anilist_id&ep` | [ingest_api.py:105](ingest_api.py#L105) | if cached, bump `last_access` (keep-warm) — the serving layer's anti-evict hook |
| `GET /status` | [ingest_api.py:110](ingest_api.py#L110) | observability: `{inflight, queued_ondemand, queued_precache, cap_gb}` |

### The two-lane priority queue — the core design

The whole point of the queue is the **"on-demand never starved by pre-cache"**
invariant. `precache.py` can flood the system with the entire airing slate; a
real viewer who opens a cold episode one second later must still jump ahead.
A single priority queue would work in theory, but a single *bounded* queue has a
fatal failure mode: if pre-cache fills it to the cap, an on-demand request hits
`queue.Full` and is **rejected outright** — the viewer's episode never caches.
Two physically separate lanes fix this:

```
_hi  queue (maxsize 50)   ← the REQUESTED episode of a real on-demand open
_lo  queue (maxsize 60)   ← all prefetch (E+1..) AND all pre-cache work
```

`enqueue()` ([ingest_api.py:64](ingest_api.py#L64)) routes each item:

```python
lane = _hi if (e == ep and not precache) else _lo   # ingest_api.py:76
```

- The **exact requested episode** of an interactive open → `_hi`.
- Its **prefetch** (`E+1 .. E+PREFETCH`) → `_lo` (the viewer isn't watching it *yet*).
- Everything from `precache.py` (which sets `precache=1`) → `_lo`.

`_worker()` ([ingest_api.py:39](ingest_api.py#L39)) **always drains `_hi`
first**, falling back to `_lo` only when `_hi` is empty:

```python
try:
    aid, ep = _hi.get_nowait(); q = _hi          # on-demand first
except queue.Empty:
    aid, ep = _lo.get(timeout=0.5); q = _lo      # else a pre-cache item
```

Because the lanes are separate `queue.Queue`s with separate caps, a full `_lo`
(pre-cache backlog) **cannot** make `_hi.put_nowait()` raise `Full` — an
on-demand open is accepted as long as `_hi` has room (50 slots). That is the
structural guarantee the comments at [ingest_api.py:9-11](ingest_api.py#L9) and
[:32-33](ingest_api.py#L32) describe: *"a full pre-cache backlog can never
reject/starve an on-demand open."*

### Dedup, in-flight, and keep-warm in one pass

`enqueue()` walks `range(ep, ep+1+PREFETCH)` and for each episode makes one of
three decisions under the lock ([ingest_api.py:68-86](ingest_api.py#L68)):

```
for e in [ep .. ep+PREFETCH]:
  ├─ cache_db.is_cached(aid,e,"sub") ?  ── yes ──►  cache_db.touch()  → warmed[]   (anti-evict)
  └─ no:
       ├─ (aid,e) in _inflight ?        ── yes ──►  skip (already queued/building)
       └─ lane.put_nowait((aid,e)) ──► add to _inflight, started[]
                └─ queue.Full ──► skip (lane saturated; back-pressure)
```

`_inflight` (a `set`, guarded by `_lock`) is the dedup ledger across **both**
lanes: an entry is added when queued and removed in the worker's `finally`
([ingest_api.py:60-61](ingest_api.py#L60)). So concurrent opens of the same
episode collapse to one build, and the queue can never hold two copies of the
same `(aid, ep)`.

The `is_cached → touch` branch is doubly important: a viewer re-opening an
**already-cached** episode bumps its `last_access`, which is exactly what keeps
the hot set warm and pushes cold episodes to the front of the eviction line
(see [§ LRU eviction](#lru-eviction--lru-trim-to-the-gb-cap)). `PREFETCH=1` by
default, so opening ep N also queues ep N+1 into `_lo` — the "next episode"
prefetch — at low priority so it never competes with another viewer's *current*
episode.

### Worker body — build, then evict, never crash the loop

```python
if not cache_db.is_cached(aid, ep, "sub"):                     # re-check (raced opens)
    subprocess.run([PY, INGEST, "episode", aid, ep], timeout=5400)
    subprocess.run([PY, INGEST, "evict", CAP_GB], timeout=600) # trim AFTER each build
```
([ingest_api.py:48-58](ingest_api.py#L48))

Every exception is swallowed ([ingest_api.py:57](ingest_api.py#L57)) and
`_inflight.discard()` always runs in `finally` — a single bad release can never
kill a worker thread or leak an in-flight entry. The `is_cached` re-check inside
the worker closes the race where two requests for the same episode slipped
through before either started building. Eviction runs **after every build**, so
the cache self-trims continuously rather than in a separate sweep.

---

## The pre-cache worker (airing slate, low-priority, parked)

`precache.py` is the proactive lever from doc [12](12-cold-start-and-instant-playback.md):
fill the popular catalog *before* anyone opens it, so cold-start becomes *rare*,
not merely *fast*. It is a thin client of `ingest_api` — it owns no storage and
no concurrency logic; it just feeds URLs into the `_lo` lane and lets the queue
+ eviction do the bounding.

| Step | Code | Note |
|------|------|------|
| Pull airing slate | [precache.py:30](precache.py#L30) `airing_slate()` | AniList `status:RELEASING, sort:TRENDING_DESC`, top `PRECACHE_TOP_N=20` |
| Compute aired eps | [precache.py:36](precache.py#L36) `aired_eps()` | `nextAiringEpisode-1` (or `episodes`) — only episodes that have actually aired |
| Pick which eps | [precache.py:63](precache.py#L63) | `{1} ∪ [aired-MAX_EPS+1 .. aired]` — ep 1 (new-viewer entry) + the **newest** `PRECACHE_MAX_EPS=12` |
| Enqueue | [precache.py:40](precache.py#L40) `enqueue()` | `GET /ingest?…&precache=1` → `_lo` lane |

The episode-selection logic at [precache.py:63](precache.py#L63) is deliberate
and called out in the comment: pulling the **oldest** episodes (1..N) would miss
the *newest* episode of an ongoing show — which is exactly the demand spike
(this week's release is what most viewers open). So it pre-pulls ep 1 + the
latest block, not the front of the season.

Idempotent + self-limiting by construction: re-running is cheap because every
`enqueue` dedups against cached/in-flight, and the queue + LRU cap bound total
work and storage. It runs `run_once()` (cron) or `--loop` with
`PRECACHE_INTERVAL=1800`s ([precache.py:74-82](precache.py#L74)), pacing AniList
+ the node with a `0.25`s sleep between requests ([precache.py:69](precache.py#L69)).

**As-built status: parked.** The pre-cache worker is *built and validated* but
intentionally **not running** on `vast-canada-3` — that node is an ephemeral
test box, and a continuously-running slate pre-fill belongs on the persistent
**production** origin (so the cache it builds isn't thrown away when the test
node is recycled). The on-demand path (`ingest_api` ← backend trigger) runs
live; the pre-cache loop is a one-command start away once the production origin
exists.

---

## The SQLite cache index (`cache_db.py`)

The index is the **source of truth for what is cached** — one row per cached
HLS package — and the substrate the evictor walks. It lives at
`/data/cache/index.db` (WAL mode, [cache_db.py:44](cache_db.py#L44)) next to the
HLS files it tracks. `is_cached`/`touch`/`register`/`evict` are the only API the
rest of the system needs.

### Schema ([cache_db.py:18-39](cache_db.py#L18))

**`episodes`** — one row per `(anilist_id, ep, category)` HLS package:

| Column | Purpose |
|--------|---------|
| `anilist_id, ep, category` | PRIMARY KEY — `category` is `sub`/`dub` (self-host builds land under `sub`) |
| `path` | `/data/cache/{anilist_id}/{ep}/{category}/` — the dir nginx serves |
| `bytes` | whole-package size (sum of all files) — the unit the LRU sums against the cap |
| `created`, `last_access` | `last_access` drives LRU ordering; `touch()` bumps it |
| `renditions` | JSON `["1080p","720p","480p"]` — surfaced to the catalog |
| `audio_tracks`, `sub_langs` | track counts/langs (JSON) — coverage metadata |
| `source_title` | the release the package was built from (provenance/debug) |
| `pinned` | `1` = **never evicted** (manual `pin` for must-keep episodes) |

**`mapping_cache`** — the ani.zip→AniDB mapping persistence
([cache_db.py:34-38](cache_db.py#L34)): `anilist_id PRIMARY KEY`, `payload`
(serialized map), `fetched` (epoch). This is what lets `ingest.py` serve a
stored mapping (warm `0.001`s vs cold `0.36`s) and **survive an ani.zip
outage** — see [§ Mapping persistence](#mapping-persistence--the-second-cache).

### Core operations

| Function | Code | Behaviour |
|----------|------|-----------|
| `register()` | [cache_db.py:57](cache_db.py#L57) | `dir_bytes(path)` then UPSERT (`ON CONFLICT … DO UPDATE`) — a rebuild updates bytes/renditions/last_access in place, never duplicates |
| `is_cached()` | [cache_db.py:87](cache_db.py#L87) | row exists **AND** `os.path.isdir(path)` — verifies the files are *actually on disk*, not just indexed (catches a row whose dir was removed out-of-band) |
| `touch()` | [cache_db.py:75](cache_db.py#L75) | `last_access = now` — the keep-warm primitive |
| `cached_eps()` | [cache_db.py:94](cache_db.py#L94) | sorted ep list for `(anime, category)` — feeds `push_cache_state` coverage |
| `evict()` | [cache_db.py:131](cache_db.py#L131) | LRU-trim to the GB cap (below) |
| `reindex()` | [cache_db.py:159](cache_db.py#L159) | bootstrap the index by scanning `*/*/*/master.m3u8` — rebuilds the DB from disk after a loss; skips non-numeric demo dirs |
| `mapping_get/put()` | [cache_db.py:102](cache_db.py#L102),[:109](cache_db.py#L109) | read/UPSERT the persisted mapping |

`is_cached` checking the directory (not just the row) is the safety net that
makes the index trustworthy: if a package is deleted by hand or a build
half-failed, the system treats it as un-cached and re-ingests rather than
serving a 404 to a viewer.

### LRU eviction — LRU-trim to the GB cap

`evict(cap_gb)` ([cache_db.py:131](cache_db.py#L131)) enforces the storage
budget. It is the only thing that deletes video, and it deletes **whole
episodes**, least-recently-accessed first, until total bytes ≤ cap:

```
while SUM(bytes) > cap:
    row = SELECT … WHERE pinned=0 ORDER BY last_access LIMIT 1   # oldest unpinned
    if no row:  break          # only pinned rows left — can't go lower
    rmtree(row.path)           # delete the HLS package
    rmdir empty {ep}/ and {anilist_id}/ parents   # tidy the tree
    DELETE the row; commit
```

Design points, and why:

- **LRU by `last_access`, not `created`** — a popular old episode that viewers
  keep opening (each open `touch`es it via `enqueue`'s warmed branch, or the
  serving layer's `/touch`) stays; a freshly-built episode nobody re-watches is
  evicted first. This is the "keep the hot set" property.
- **Pinned rows are immune** ([cache_db.py:140](cache_db.py#L140)
  `WHERE pinned=0`) — the loop `break`s if only pinned rows remain, so the cap
  can be *exceeded* by pins. Intentional: a pin is an operator promise that an
  episode stays regardless of budget.
- **Empty-parent cleanup** ([cache_db.py:146-152](cache_db.py#L146)) removes the
  now-empty `{ep}/` and `{anilist_id}/` dirs so the cache tree doesn't
  accumulate skeleton directories.
- **Runs after every build**, triggered from the worker
  ([ingest_api.py:53](ingest_api.py#L53)) — the cache is continuously trimmed,
  never allowed to balloon between sweeps. `CACHE_CAP_GB` is the budget knob
  (default `300` GB; HLS-at-rest currently ~63 GB).

`evict()` returns `{freed_gb, removed:[…], evicted:N}` so the eviction is
observable, and the CLI driver feeds `removed` into a cache-state re-sync
(next section).

### Mapping persistence — the second cache

The `mapping_cache` table is `cache_db`'s contribution to ingest resilience.
`ingest.py`'s `map_anidb(id, want_ep)` ([ingest.py:149](ingest.py#L149)) wraps
the live ani.zip+AniList fetch:

1. Read the stored map (`mapping_get`, [ingest.py:154](ingest.py#L154)).
2. If it **covers** `want_ep` (`_covered`, [ingest.py:135](ingest.py#L135) — the
   episode is in `eid_to_ep`/`abs_to_ep`/`relnum_to_ep`, or within the trusted
   episode count) **and** is within `MAP_TTL=12h`, serve it (warm `~0.001`s).
3. Else refetch live and `mapping_put` ([ingest.py:165](ingest.py#L165)) (cold `~0.36`s).
4. **If the live fetch fails** (ani.zip/AniList down), fall back to the **stale**
   stored map ([ingest.py:167-170](ingest.py#L167)) — re-ingesting a known anime
   still works through an upstream outage.

`_covered` forces a refetch for a *just-aired* episode the cached map predates
([ingest.py:135-147](ingest.py#L135)), so a new episode is never missed merely
because an old map is still in TTL. Serialization handles the int keys + the
`relnum_to_ep` tuple keys that JSON can't represent directly
([ingest.py:122-133](ingest.py#L122)). Episode **titles** ride along in the same
payload (`ep_titles`), which is what lets the catalog show real episode titles
(next section).

---

## Build → register → push cache-state

When a worker runs `ingest.py episode N E`, the build path
([ingest.py:692](ingest.py#L692) `ingest_one`) is:

```
select_release → download / download_batch_file → build_and_register → push_cache_state
```

### Download (single file or per-file batch extract)

| Path | Code | Behaviour |
|------|------|-----------|
| Single release | [ingest.py:570](ingest.py#L570) `download()` | `transmission-remote -a <url>`, poll `Percent Done` until `100`/`Seeding`, return the biggest `.mkv` inside |
| Batch pack | [ingest.py:618](ingest.py#L618) `download_batch_file()` | add pack, list files, `select_best_video_file(files, ep, season)`, **deselect every other file** (`-G`), download only ep `E`'s file — a 143 GB One Piece pack costs ~200 MB |

The batch path sets a per-torrent ratio (`-sr 999`,
[ingest.py:645](ingest.py#L645)) so a global ratio-0 stop doesn't kill the
download before the wanted file finishes — a real edge case the comment flags.

### Build + register

`build_and_register()` ([ingest.py:660](ingest.py#L660)) invokes
`hls_build.py` to produce the on-disk package under
`/data/cache/{N}/{E}/{category}/` (remux H.264 master or NVENC, the 720/480
ladder, **every** audio + subtitle track, embedded fonts, `subs/tracks.json` —
all detailed in doc [10](10-pipeline-prototype-measured.md)), parses the JSON
report, then `cache_db.register()`s the row with the renditions, audio-track
count, and converted sub languages. After this returns, **the package is live**:
nginx already serves it (the files exist; the index row is just bookkeeping for
eviction + coverage).

### push_cache_state — telling the backend what's cached

`push_cache_state(anilist_id, mp)` ([ingest.py:674](ingest.py#L674)) is the link
back to the APP host. After every build it POSTs to the backend
`POST /api/watch/cache-state` (token-auth, `X-Ingest-Token`):

```json
{ "anilist_id": N,
  "total_eps": <ani.zip episode count>,
  "cached": { "sub": [1,2,3,…], "dub": [] },
  "ep_titles": { "1": "…", "2": "…" } }
```

The backend upserts this into Mongo `selfhost_cache`; the catalog detail + card
endpoints then expose `selfhost` (coverage + episode titles) **without ever
probing the origin**. That's what drives the green ★ AniChan coverage badge
(`N/total`) on cards and the per-episode green markers + titles in the watch
panel. It is **best-effort**: wrapped in try/except ([ingest.py:689](ingest.py#L689)),
gated on `BACKEND_URL` + `INGEST_TOKEN` being set — a failed push never fails an
ingest. `BACKEND_URL` is the public backend (`http://70.30.158.46:43577`).

### Eviction → cache-state sync (closing the loop)

A subtle correctness requirement: when `evict()` **deletes** episodes, the
backend's `selfhost_cache` would otherwise still advertise them — showing a
green marker for an episode that no longer exists. So the `evict` CLI command
re-syncs every affected anime ([ingest.py:796-803](ingest.py#L796)):

```python
res = cache_db.evict(cap_gb)
for aid in sorted({r["anilist_id"] for r in res["removed"]}):
    push_cache_state(aid, map_anidb(aid))   # map_anidb here uses the CACHED map → no ani.zip hit
```

`map_anidb(aid)` with no `want_ep` here intentionally rides the persisted
mapping (covered + in-TTL) so the eviction sync is cheap and doesn't hammer
ani.zip. The result: the catalog's coverage always reflects what's *actually* on
the origin — adds on build, removals on evict.

---

## Serving — static HLS at rest over nginx

Serving is the boring (and fast) part by design. Once `build_and_register`
writes the package, every request is a **pure static file read** — no ffmpeg
ever runs on the hot path, no per-viewer transcode exists.

```
/data/cache/{anilist_id}/{ep}/{category}/
  master.m3u8        # EXT-X-STREAM-INF variants + EXT-X-MEDIA audio/sub groups
  v0/ index.m3u8 seg*.ts     # native master (remux if H.264/8-bit, else NVENC)
  v1/ … 720         v2/ … 480
  a0/ a1/ …                  # one HLS-AAC rendition per audio track (sub + dub)
  subs/ <lang><n>.vtt + .m3u8 (+ .ass) + fonts/ + tracks.json
```

nginx serves `/data/cache` on `:8080` internally, mapped to public **`:35346`**
on `vast-canada-3`. As measured in doc [10](10-pipeline-prototype-measured.md):
`200` + `Accept-Ranges: bytes` + `immutable` on segments, Range → `206 Partial
Content`, `master.m3u8` as `application/vnd.apple.mpegurl`. Static serving
benchmarked at **5,677 req/s / ~113 Gbit/s** over loopback — the origin is
**NIC-egress-bound**, never CPU/disk-bound; the box is the cache *origin*, and an
edge mesh (doc [09](09-streaming-at-scale.md)) is the horizontal scaling lever.

### The origin stays hidden

The browser **never** sees `159.48.242.1:35346`. The backend proxies the HLS
through `anichan.net/api/watch/...`:

- The self-host source probes `{ORIGIN}/{anilistId}/{ep}/{cat}/master.m3u8`; on a
  hit it's prepended as **Source 1 — ★ AniChan**.
- The `/m3u8` proxy rewrites `EXT-X-MEDIA` **audio** group URIs (so the
  separate-audio HLS plays) and drops the in-manifest **subtitle** group (subs
  are delivered via the player's `<track>`/JASSUB path, with the styled `.ass`
  + fonts proxied too).
- Every URL the browser fetches is `/api/watch/...` — origin IP never leaves the
  server. The dedicated `/api/watch/` nginx block on `anichan.net` is
  Range-aware, unbuffered, long-timeout; adding `proxy_cache` to `/api/watch/seg`
  is the documented next edge-cache step.

---

## Env / ops reference

| Var | Default | Where | Meaning |
|-----|---------|-------|---------|
| `CACHE_CAP_GB` | `300` | ingest_api | LRU byte budget (passed to `ingest.py evict`) |
| `PREFETCH` | `1` | ingest_api | current ep + this many ahead → `_lo` |
| `MAX_CONC` | `2` | ingest_api | worker threads (GPU/disk concurrency) |
| `HI_QUEUE_MAX` / `QUEUE_MAX` | `50` / `60` | ingest_api | `_hi` / `_lo` lane caps |
| `INGEST_TOKEN` | — | ingest_api, ingest | shared secret (`== backend SELFHOST_INGEST_TOKEN`) |
| `BACKEND_URL` | — | ingest | backend base for `push_cache_state` (`http://70.30.158.46:43577`) |
| `PRECACHE_TOP_N` / `PRECACHE_MAX_EPS` / `PRECACHE_INTERVAL` | `20` / `12` / `1800` | precache | slate size / eps per title / loop interval |
| `MAP_TTL` | `12h` | ingest (const) | mapping cache freshness |

**Live on the origin:** `ingest_api` (tmux `ingestapi` via
`/data/run_ingest_api.sh`, public `:35147`) + nginx (`/data/cache`, public
`:35346`) + transmission. **Parked:** `precache.py` (belongs on the persistent
production origin, not the ephemeral test node). Bootstrap after a node loss:
`cache_db.py reindex` rebuilds the index from the on-disk `master.m3u8` files.

---

### Summary

The video origin is a closed loop: a **bounded, two-lane priority queue**
(`ingest_api`) accepts on-open triggers, keeps interactive opens (`_hi`)
structurally un-starvable by bulk pre-cache (`_lo`), dedups via `_inflight`, and
keeps the hot set warm via `touch`. A fixed worker pool runs the time-bounded
`ingest.py → hls_build.py` build, which `register`s the package in a **SQLite
index** and **LRU-evicts to a GB cap** after every build; each build (and every
eviction) **pushes cache-state** to the backend so the catalog's coverage badges
and episode titles always match what's actually on disk. The result is served as
**static HLS** by nginx — egress-bound, transcode-free — proxied through
`anichan.net` so the origin IP stays hidden.
