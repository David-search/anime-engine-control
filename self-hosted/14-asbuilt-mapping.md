# 14 · As-built: mapping, discovery & selection

> Status: **as-built** (2026-06-26). The eid-driven, split-cour-proof rework
> from [13-mapping-rethink.md](13-mapping-rethink.md) is now implemented and live
> in [`ingest.py`](ingest.py) + [`relparser.py`](relparser.py). This doc
> describes the code as it runs on the video origin (`vast-canada-3`,
> `/data/`). Supersedes the "Mapping" sections of
> [11-ingest-automation.md](11-ingest-automation.md) for the matching internals.

The job: turn an **(AniList id, requested episode N)** pair into the **one correct
fansub release** to download — across split cours, absolute-numbered
long-runners, TVDB sequel relabels, just-aired lag, and chaotic release naming —
**without ever serving the wrong episode** ("never the wrong ep" is the cardinal
rule). Four stages, each with its own correctness guard:

| Stage | Code | What it produces |
|-------|------|------------------|
| A · map | [`map_anidb`](ingest.py#L149) → [`_map_anidb_live`](ingest.py#L53) | the **ctx** map: ani.zip → AniDB join tables, keyed to OUR episode number |
| A' · persist | [`mapping_cache`](cache_db.py#L34) + TTL/outage fallback | survive ani.zip outages, cheap re-ingest |
| B · discover | [`find_releases`](ingest.py#L233) | a deduped release list, eid-first |
| C · match | [`map_episode`](ingest.py#L383) / [`map_batch`](ingest.py#L356) | per-release → (our ep, confidence) |
| D · select | [`select_release`](ingest.py#L514) + [`score`](ingest.py#L493) | the single best release for ep N |

---

## 1. Stage A — ani.zip → AniDB mapping (`_map_anidb_live`)

[`_map_anidb_live`](ingest.py#L53) fetches two sources and fuses them into the
**ctx** dict every later stage reads:

- **AniList GraphQL** ([L54-57](ingest.py#L54)) — `episodes` (authoritative total),
  `synonyms`, and `title{romaji english native}` for keyword discovery.
- **ani.zip** `api.ani.zip/mappings?anilist_id=` ([L58](ingest.py#L58)) — the bridge.
  Its `episodes` object is a **dict whose KEY is the AniList episode number** and
  whose value carries `anidbEid`, `episodeNumber` (season-relative),
  `absoluteEpisodeNumber`, `seasonNumber`, `airdate`, and a `title`.

### The re-keying — why the dict KEY is everything

The old bug (root cause in [13 §1](13-mapping-rethink.md)): the mapper keyed its
tables on `episodeNumber` (season-relative) and discarded the dict key. For a
split cour those differ — Dr. Stone Cour 3 ep "**1**" has `episodeNumber=25`,
`absoluteEpisodeNumber=83`, `seasonNumber=4`. The request arrives cour-relative
(`ep=1`), so a table keyed on `25` is unreachable.

The fix: **every table value is the dict key `int(k)`** ([L80](ingest.py#L80)) —
the number the request will use. Three join tables, all → our ep
([L68-94](ingest.py#L68)):

| Table | Maps | Built from | Purpose |
|-------|------|------------|---------|
| `eid_to_ep` | AniDB episode id → our ep | `v["anidbEid"]` | the parser-free join (authoritative) |
| `abs_to_ep` | fansub absolute # → our ep | `v["absoluteEpisodeNumber"]` | "One Piece - 1085" |
| `relnum_to_ep` | `(season, seasonEp)` → our ep | `(v["seasonNumber"], v["episodeNumber"])` | `S04E25` → our 1 |

Plus `ep_airdate` (our ep → ISO date, for the airdate guard) and `ep_titles` (our
ep → episode title, pushed to the catalog). `season` is the entry's TVDB season
([L102-103](ingest.py#L102)); `part` is the **cour number parsed from the
AniList title** (`rp.explicit_part(english/romaji)`, [L109](ingest.py#L109)) —
e.g. "Cour 3" → `part=3` — used to reject a different cour's releases.

### First-wins dup-row guard

ani.zip rows are not clean: **199221's finale row is mislabeled
`episodeNumber=25` / `absolute=83` — identical to ep1.** Under last-write-wins
that finale would clobber `(4,25) → 1`, mis-mapping every un-eid'd `S04E25`
release to ep 13. The code iterates **in numeric episode order** (`sorted(...,
key=_ek)`, [L78](ingest.py#L78); non-numeric specials sort to `10**9`) and writes
with **`setdefault`** ([L86-100](ingest.py#L86)) so the **first (real) row wins**
and the duplicate is ignored. `ep_titles` uses the same first-wins rule
([L100-101](ingest.py#L100)). Specials (`ours < 1`) are skipped
([L83-84](ingest.py#L83)).

`episodes` is `AniList.episodes or az_count or None` ([L112](ingest.py#L112)) —
AniList's count is trusted over a raw `len(episodes)` because of those duplicate
rows.

---

## 2. Stage A' — mapping persistence (cache / TTL / outage fallback)

ani.zip and AniList are external and occasionally down. A re-ingest of a known
anime must not require them. [`map_anidb(anilist_id, want_ep)`](ingest.py#L149)
wraps the live fetch with the [`mapping_cache`](cache_db.py#L34) SQLite table
(`payload` JSON + `fetched` epoch). `MAP_TTL = 12h` ([L120](ingest.py#L120)).

Decision flow ([L154-171](ingest.py#L154)):

```
row = mapping_get(id)                              # cached payload + fetched ts
cached = _deserialize_map(row)  (if present, on parse-fail -> None)
if cached and _covered(cached, want_ep) and age < MAP_TTL:
        return cached                              # warm path (~0.001s)
try:
        live = _map_anidb_live(id); mapping_put(id, _serialize_map(live)); return live   # cold (~0.36s)
except:
        if cached: return cached                   # ani.zip/AniList DOWN -> stale map
        raise
```

Three guards make this safe:

- **[`_covered`](ingest.py#L135)** — a cached map is reused only if it already
  knows `want_ep` (present in any of the three tables' *values*, [L140-142](ingest.py#L140)).
  A **just-aired episode that postdates the cache forces a refetch**. If ani.zip
  had no per-episode rows at all, it falls back to `1 ≤ want_ep ≤ episodes`
  ([L144-146](ingest.py#L144)). `want_ep=None` (series/coverage commands) is
  always "covered" so they never force a refetch for the whole season.
- **TTL** — even a covering map refetches after 12h to pick up new
  episodes/title fixes.
- **Outage fallback** — a live-fetch exception falls back to the stale cached map
  ([L167-170](ingest.py#L167)) so a known anime still re-ingests when ani.zip is
  down; only a *cold* anime (no cache) propagates the error.

**Serialization** ([`_serialize_map`](ingest.py#L122) / [`_deserialize_map`](ingest.py#L128)):
JSON can't hold int keys or tuple keys. The int-keyed tables round-trip via
`{int(kk): vv}` on load ([L131](ingest.py#L131)); `relnum_to_ep`'s **tuple keys**
are flattened to a `relnum_list` of `[season, ep, our_ep]` triples on save
([L124](ingest.py#L124)) and rebuilt to `{(s,e): v}` on load ([L132](ingest.py#L132)).

Measured: cold 0.36s, warm 0.001s. Episode **titles** also ride this cache, so
the catalog gets them even on a re-ingest that never touches ani.zip.

---

## 3. Stage B — discovery (`find_releases`), eid-first tiers

[`find_releases`](ingest.py#L233) gathers candidate releases from AnimeTosho +
Nyaa across **four tiers**, deduped by **info-hash** (falling back to
`torrent_url`, [`key_of`](ingest.py#L239)). Each release is tagged `_trusted`
(authoritative anidb mapping) and `_source`. Pagination stops at the first short
page (`< 50`, [`pages`](ingest.py#L253)).

| Tier | Query | Trusted? | Token filter? | Why it exists |
|------|-------|----------|---------------|----------------|
| **0 · eid** | `?eid=<eid>&only_tor=1` | yes | no | **collapses `S04E25` / `Part 3 - 01` / `S4 - 25` onto one AniDB episode id — parser-free, authoritative** |
| **1 · aid** | `?aid=<anidb_id>&only_tor=1` | yes | no | AniDB-mapped releases (often a subset; early eids buried deep in reverse-chron pages) |
| **2 · keyword** | `?q=<clean title>` | no | yes (≥2 tokens) | fills un-mapped releases |
| **2b · batch** | `?q=<clean title> batch` | no | yes | season packs / long-running back-catalog |
| **3 · Nyaa** | `nyaa.si ?page=rss` (+ ` batch`) | no | yes | **just-aired episodes AnimeTosho hasn't indexed yet** |

### Tier 0 — the eid query (the robustness win)

`eids` are supplied by the caller as the AniDB episode ids for the wanted
episodes. [`cmd_episode`](ingest.py#L712) inverts `eid_to_ep` to
`ep2eid` and passes `[ep2eid[a.ep]]`; [`cmd_series`](ingest.py#L746) passes up to
80. The query ([L260-262](ingest.py#L260)) hits
`feed.animetosho.org/json?eid=<eid>` — AnimeTosho returns **every release it
auto-mapped to that exact AniDB episode**, regardless of how the fansubber
numbered it. This is what makes split-cour discovery deterministic: instead of
hoping a title parse reads "Part 3 - 01" as cour ep 1, the eid groups them for us.

### Tier 2 keyword cleanup + relevance gate

AnimeTosho full-text search is punctuation/suffix-sensitive, so
[`_clean_q`](ingest.py#L191) strips punctuation and `"N(st|nd|...)? season N"`
down to distinctive core words. To reject keyword false positives,
[`add(..., toks)`](ingest.py#L243) only keeps a release whose title contains
**≥2 distinctive title tokens** ([`_relevant`](ingest.py#L187),
[`_tokens`](ingest.py#L179) — 4+ char words minus a stoplist). Tiers 0/1 skip
this gate (they're already authoritative).

### Tier 3 — Nyaa fallback

[`fetch_nyaa`](ingest.py#L200) parses Nyaa's RSS into **AnimeTosho-shaped dicts
with `anidb_eid=None`** ([L228](ingest.py#L228)) — so they *cannot* use the eid
fast-path and must pass the season+airdate-guarded title mapping. It carries
`info_hash` (for dedup), `seeders`, and `timestamp` (the airdate guard needs it).
Nyaa is reachable from the origin (no Cloudflare block here).

---

## 4. Stage C — per-release episode determination (`map_episode`)

[`map_episode(rel, ctx)`](ingest.py#L383) returns `(our_ep, confidence)` or
`(None, None)`. Confidence is ranked **eid > sxxeyy > absolute > airdate >
parsed** ([`CONF_RANK`](ingest.py#L298)); `STRONG` = everything but `parsed`.
The whole function is a **tiered cascade that rejects anything ambiguous** rather
than guessing — that is the "never the wrong ep" rule made code.

### Decision flow

```
0. is_batch?            -> (None,None)   # batches go through map_batch, not here
1. anidb_eid present?
     eid in eid_to_ep   -> (ep, "eid")            # authoritative, zero parsing
     else               -> (None,None)            # eid = a special / other cour -> REJECT
2. SxxEyy present?  (extract_sxxeyy)
     (es,ee) in relnum_to_ep            -> (ep,"sxxeyy")     # S04E25 -> our 1
     relmap has season es (but not ee)  -> absolute-or-REJECT  # wrong cour of a known season
     no relmap, es == our season        -> legacy 1<=ee<=n / absolute
     ee is a continuous absolute        -> (abs,"absolute")  # S01E19 -> our 7
     es==1, our season>1, airdate OK    -> (ee,"airdate")    # TVDB sequel relabel, date-confirmed
     else                               -> (None,None)
3. no SxxEyy:
     is_wrong_season(t, season)         -> (None,None)       # explicit S-tag != ours
     ep_part set & rel_part != ep_part  -> (None,None)       # DIFFERENT cour of same season
     raw = extract_episode_number(t)
     ep_part & rel_part == ep_part      -> (raw,"sxxeyy")    # 'Part 3 - 06' -> cour-relative 6
     else                               -> _resolve_num(raw, explicit_season(t))
```

### Tier 1 — eid (authoritative)

[L390-399](ingest.py#L390). If the release carries an `anidb_eid` and it's in
`eid_to_ep`, return it with confidence `"eid"` — **no title parsing at all**. If
the eid is present but *not* in our map, it belongs to a special or a different
cour/season → **reject** (don't fall through to a fuzzy parse). This is the path
Tier-0 discovery feeds, and it's why split cours just work.

### Tier 2 — SxxEyy, with `relnum_to_ep` as the authority

[L408-428](ingest.py#L408). [`rp.extract_sxxeyy`](relparser.py#L98) pulls
`(es, ee)`. The key insight encoded in [`_relmap_has`](ingest.py#L327): **when
ani.zip has season-relative data for the embedded season, that table is
authoritative for it** — a number it doesn't list for that season is a different
cour and is rejected, not mis-served.

- `(es,ee) ∈ relnum_to_ep` → that's our ep ([L412-413](ingest.py#L412)). `S04E25`
  → our 1.
- `_relmap_has(es)` but `(es,ee)` absent → try fansub-absolute (`ee > n`), else
  **reject** ([L414-417](ingest.py#L414)). This is what kills `S04E06` ("cour 1")
  for a cour-3 request — season 4 is in the map but `(4,6)` isn't our episode.
- No relmap for `es`, and `es == our season` → legacy path: `1 ≤ ee ≤ n`, or
  absolute ([L418-423](ingest.py#L418)).
- `es ≠ our season` but `ee` is a continuous absolute → `absolute`
  ([L424-425](ingest.py#L424)): `S01E19` of a sequel = our absolute 19.
- `es == 1, our season > 1`, **airdate-confirmed** → `airdate`
  ([L426-427](ingest.py#L426)). The TVDB-relabel case (see below).
- else → reject.

### Tier 3 — no SxxEyy, cour/part tags then `resolve_num`

[L430-448](ingest.py#L430). Two guards first:

- [`rp.is_wrong_season(t, season)`](relparser.py#L112) — drop a release whose
  **explicit** season tag ≠ ours.
- **cour guard** ([L433-435](ingest.py#L433)): if both the entry and the release
  carry a Part/Cour number and they differ, reject — "Part 2 - 06" when we want
  Part 3.

Then [`rp.extract_episode_number(t, season)`](relparser.py#L131) gets the raw
number. If the entry and release share the same cour (`ep_part == rel_part`), the
raw number is **cour-relative** and accepted directly as `sxxeyy`
([L439-440](ingest.py#L439)) — "Part 3 - 06" → our ep 6. Otherwise
[`_resolve_num`](ingest.py#L332) maps it.

### `_resolve_num` — the collision-guarded number resolver

[`_resolve_num(raw, ctx, es_tag)`](ingest.py#L332). Resolution order with the
season-authority guard ([L344-354](ingest.py#L344)):

1. If `_relmap_has(s)` (ani.zip has season-rel data for season `s`):
   - `(s, raw) ∈ relnum_to_ep` → that ep (season-verified).
   - else `raw ∈ abs_to_ep` and `raw > n` → absolute count.
   - **else `None`** — the season is known and this number isn't ours → **a
     different cour → reject. No slop.**
2. No season-rel data: `raw ∈ abs_to_ep` and `raw > n` → absolute.
3. Direct in-range `1 ≤ raw ≤ n` → `raw` (single-cour shows with no season-rel
   data).

### The airdate guard

[`_airdate_ok`](ingest.py#L301). A bare `S01E12` is ambiguous when a 2025 S1 and a
2026 S2 share a title — TVDB groups relabel the sequel as S01. The guard accepts
the relabel only if the release's **publish epoch is within ±45 days of our
episode's ani.zip airdate** ([L311-313](ingest.py#L311)). This is the only
heuristic in the cascade and it's date-anchored, not a guess; it requires
`ts` (present on AnimeTosho + Nyaa rows).

### Why this is "never the wrong episode"

Every tier either returns an **authoritative or anchored** answer or returns
`(None, None)`. A `(None, None)` becomes a reported **gap**, never a substitution.
The cross-cour cases that used to silently mis-serve — `S04E06` for cour 3, "Part
2 - 06" for Part 3, a duplicate finale row — are all explicit rejects.

### `relparser.py` changes that make this work

[`relparser.py`](relparser.py) is the ported Amatsu parser, hardened so **Part/Cour
is not a TVDB season**:

- `_SEASON_RX` ([relparser.py#L74](relparser.py#L74)) **dropped `part|cour`** — a
  `_PART_RX` ([L77](relparser.py#L77)) handles them separately. Previously
  `is_wrong_season` saw "Part 3" as season 3 and rejected every legitimate
  split-cour release.
- [`explicit_part`](relparser.py#L89) — the cour number (separate from season),
  consumed by the cour guards in `map_episode`/`map_batch`.
- [`extract_episode_number`](relparser.py#L131) **strips `Part N`/`Cour N` before
  episode extraction** ([L139](relparser.py#L139)) so "Part 3 - 06" reads as
  episode **6**, not 3.
- [`extract_sxxeyy`](relparser.py#L98) returns the embedded `(season, ep)` but
  the caller never trusts the season as authoritative — `relnum_to_ep` + airdate
  arbitrate.

### Batches — `map_batch`

[`map_batch`](ingest.py#L356) handles multi-episode packs (resolved by range, not
single-ep). It rejects wrong-season ([L363](ingest.py#L363)) and wrong-cour
([L365-366](ingest.py#L365)) packs, then resolves the range: a same-cour pack's
range is cour-relative ([L369-370](ingest.py#L369)); otherwise each endpoint goes
through `_resolve_num` ([L371-372](ingest.py#L371)). A bare batch keyword with no
range maps to the whole season `(1, n)` only when the season/cour matches
([L376-381](ingest.py#L376)). [`_is_batch`](ingest.py#L317) is conservative
(explicit range or batch keyword) so a single episode is never misread as a pack.

---

## 5. Stage D — selection (`select_release`) + the seeder floor

[`select_release(releases, ep, ctx, allow_hevc)`](ingest.py#L514) picks the one
best release for episode `ep`. It maps every release, partitions into **singles**
(map to exactly `ep`) and **batches** (a pack covering `ep`), and ranks.

Hard filters first ([L521-526](ingest.py#L521)): no `torrent_url`, resolution
`< 480p`, or HEVC-when-disallowed are dropped before ranking.

### The ranking key — correctness outranks seeds

Singles are sorted by the tuple **`(CONF_RANK, _live, score)`** descending
([L529, L535](ingest.py#L529)):

1. **confidence** ([`CONF_RANK`](ingest.py#L298)) — an `eid` match always beats a
   `parsed` one. Correctness first.
2. **`_live`** — alive (1) before near-dead (0).
3. **`score`** — quality tiebreak.

So a dead but authoritative release still beats a seeded fuzzy guess of lower
confidence, but among equal-confidence releases a seeded one wins. Batches are
the fallback, sorted `(_live, score)` ([L538](ingest.py#L538)); a batch hit
returns confidence `"batch"`, signalling `ingest_one` to extract one file via
[`download_batch_file`](ingest.py#L618) rather than download the whole pack.

### `score` — the quality function

[`score(rel, allow_hevc)`](ingest.py#L493):

| Factor | Points | Why |
|--------|--------|-----|
| 1080p / 720p / 480p | 1000 / 600 / 300 | resolution dominates |
| MultiSub | +200 | one download = every subtitle language |
| **not** HEVC (H.264) | +150 | H.264 → instant remux master (no re-encode) |
| seeders | `min(s,500)/10` | capped so seeders never outweigh quality/codec |

The seeder cap (max +50) is deliberate — a well-seeded 720p HEVC must not beat a
1080p H.264 MultiSub.

### The seeder floor — `_live`

[`MIN_SEED = 1`](ingest.py#L504); [`_live(rel)`](ingest.py#L506) returns 1 if
`seeders ≥ MIN_SEED` **or seeders is unknown** (some AnimeTosho rows omit it —
don't penalize), else 0. Without this floor, a perfectly-scored but **dead**
1080p H.264 MultiSub would top the `score` and be picked every time, then never
download. Putting `_live` *above* `score` but *below* confidence in the sort key
means a near-dead torrent is a genuine last resort, used only when nothing alive
of equal correctness exists.

---

## 6. Worked example — 199221 "Dr. STONE: SCIENCE FUTURE Cour 3" ep 1

The canonical case that drove the rework. Request: `ingest.py episode 199221 1`.

**Stage A.** ani.zip's `episodes["1"]` = `{anidbEid: 301711, episodeNumber: 25,
absoluteEpisodeNumber: 83, seasonNumber: 4}`. AniList title "Dr. Stone: Science
Future" → `part = explicit_part(...)`. The re-keyed tables
([L80-94](ingest.py#L80)):

```
eid_to_ep[301711]   = 1          # the dict KEY, not 25
abs_to_ep[83]       = 1
relnum_to_ep[(4,25)]= 1          # S04E25 -> our 1
season = 4   part = 3 (from "Cour 3"/"Part 3")
```

The mislabeled **finale row** also says `episodeNumber=25 / absolute=83`. Because
iteration is in numeric order with `setdefault`, the real ep1 row writes `(4,25)
→ 1` first and the finale is ignored — without this, `S04E25` releases would map
to the finale instead of ep 1.

**Stage A'.** Persisted to `mapping_cache`; a re-open reuses it (`_covered`
true — ep 1 ∈ values).

**Stage B.** `ep2eid[1] = 301711` → Tier-0 query
`feed.animetosho.org/json?eid=301711&only_tor=1`. AnimeTosho returns every release
auto-mapped to that AniDB episode — the `S04E25`, `Part 3 - 01`, and
`Dr. Stone S4 - 25` releases, **all carrying `anidb_eid=301711`** — regardless of
their wildly different title numbering. Tiers 1-3 add more, deduped by info-hash.

**Stage C.** Each eid-tagged release hits [`map_episode`](ingest.py#L383) Tier 1:
`301711 ∈ eid_to_ep` → **`(1, "eid")`**, zero parsing. A Nyaa "Part 3 - 01"
(`anidb_eid=None`) instead reaches Tier 3: not wrong-season, cour matches
(`rel_part 3 == ep_part 3`), `extract_episode_number` strips "Part 3" and reads
`1` → cour-relative **`(1, "sxxeyy")`**. A stray `S04E06` release ("Cour 1")
would hit Tier 2: `(4,6) ∉ relnum_to_ep` but `_relmap_has(4)` → **rejected**
(different cour), exactly the slop we refuse.

**Stage D.** Among the ep-1 singles, the highest `CONF_RANK` (`eid` = 5) wins;
ties broken by `_live` then `score` (prefer the alive 1080p H.264 MultiSub).
Download → `hls_build.py` → `cache_db.register` → `push_cache_state`. Dr. Stone
Cour 3 ep1 caches. **Fixed.**

---

## 7. How the matcher is driven on the request path

The auto-ingest trigger ([ingest_api.py](ingest_api.py)) and pre-cache worker
([precache.py](precache.py)) both feed this pipeline through `ingest.py episode`,
via a **two-lane** priority queue so a viewer's open is never starved by
pre-cache:

- **`_hi`** ([ingest_api.py#L34](ingest_api.py#L34), cap 50) — the **requested
  episode of an on-demand open**. Drained first ([`_worker`](ingest_api.py#L39)).
- **`_lo`** ([L35](ingest_api.py#L35), cap 60) — prefetch (the +1 ahead) and all
  pre-cache. [`enqueue`](ingest_api.py#L64) routes `e == ep and not precache` →
  `_hi`, everything else → `_lo` ([L76](ingest_api.py#L76)).
  [`precache.py`](precache.py#L43) sets `precache=1`, so the proactive slate
  always lands in `_lo`.

Separate bounded lanes mean a full pre-cache backlog can **reject** (never
*starve*) — an on-demand open always has its own 50-slot lane and is drained
ahead of the 60-slot pre-cache lane.

After each successful build, [`push_cache_state`](ingest.py#L674) POSTs
`{cached:{sub,dub}, ep_titles, total_eps}` to the backend
`POST /api/watch/cache-state` (token-auth via `X-Ingest-Token`), so the catalog
shows ★ AniChan coverage + episode titles without probing the origin. Eviction
([`cmd_evict`](ingest.py#L796)) re-pushes cache-state for every affected anime,
reusing the persisted map (no ani.zip hit) — so coverage badges stay in sync as
the LRU cache shrinks.

---

## 8. Quick reference — every guard, one place

| Guard | Code | Rejects |
|-------|------|---------|
| dup-row first-wins | `setdefault` over sorted eps ([L78-100](ingest.py#L78)) | mislabeled finale clobbering ep1's `(s,e)` |
| `_covered` refetch | [L135](ingest.py#L135) | serving a stale map for a just-aired ep |
| outage fallback | [L167-170](ingest.py#L167) | failing a re-ingest when ani.zip is down |
| ≥2-token relevance | [`_relevant`](ingest.py#L187) | keyword false positives |
| eid-not-in-map | [L399](ingest.py#L399) | a special / other-cour eid |
| `_relmap_has` authority | [L327](ingest.py#L327), [L414](ingest.py#L414), [L344](ingest.py#L344) | a wrong-cour number of a known season |
| cour-part mismatch | [L365](ingest.py#L365), [L434](ingest.py#L434) | "Part 2" release for a Part 3 request |
| `is_wrong_season` | [relparser.py#L112](relparser.py#L112) | explicit wrong-season tag |
| airdate ±45d | [`_airdate_ok`](ingest.py#L301) | a prior season's same-numbered ep |
| confidence-first sort | [L529, L535](ingest.py#L529) | a fuzzy guess beating an authoritative match |
| seeder floor `_live` | [L506](ingest.py#L506) | a dead release topping the score and never downloading |
