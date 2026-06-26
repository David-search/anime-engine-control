# 13 · Mapping rethink — eid-driven, split-cour-proof

> Status: design accepted (2026-06-26), implementation pending. Driven by the
> canonical failure **AniList 199221 "Dr. STONE: SCIENCE FUTURE Cour 3" ep1**,
> which never caches. Backed by a multi-agent tool survey (anime-relations,
> Fribb/manami, Seanime/Hayase, SeaDex, AnimeTosho eid API, Stremio/Kitsu).

## 1. Root cause — it's a keying bug, not a data gap

We already fetch everything needed. ani.zip gives, for 199221 ep "1":
`anidbEid=301711`, `episodeNumber=25` (season-relative), `absoluteEpisodeNumber=83`,
`seasonNumber=4`. The releases all exist on AnimeTosho (`S04E25`, `Part 3 - 01`,
`Dr. Stone S4 - 25`), each carrying `anidb_eid=301711`.

But [ingest.py:64](ingest.py#L64) does `epn = int(episodeNumber or … or k)` — it
**prefers the season-relative `episodeNumber` (25) and discards the ani.zip dict
key `"1"`, which IS the AniList request number.** Every ctx map is then keyed in
the season-relative space: `eid_to_ep[301711]=25`, `abs_to_ep[83]=25`. The request
arrives as cour-relative `ep=1`, and [`select_release`](ingest.py#L393) keeps only
releases whose mapped episode `== 1`. 25 ≠ 1 for every real release →
`[err] no release for ep1`. **The cour→season offset (1→25) is fetched and indexed,
but on the wrong side of the relation to ever be reached by the request.**

This breaks **every split-cour / continuation / absolute-numbered long-runner.**

## 2. Tool landscape (what the survey found)

| # | Tool / dataset | Gives us | Split-cour? | Effort | Notes |
|---|---|---|---|---|---|
| 1 | **ani.zip** `api.ani.zip/mappings?anilist_id=` | per-ep `anidbEid`, `episodeNumber`, `seasonNumber`, `absoluteEpisodeNumber`, airdate | **Yes** (dict key = AniList ep) | **none** (already called) | the bridge; just consume the key |
| 2 | **AnimeTosho `?eid=`** `feed.animetosho.org/json?eid=<eid>&only_tor=1` | every release auto-mapped to one AniDB episode, tagged `anidb_eid/fid` | **Yes, parser-free** (eid 301711 → 27 releases) | low | the durable robustness win |
| 3 | **Seanime offset math** (`media_tree_analysis.go`, MIT) | deterministic absolute↔season↔cour conversion | Yes | med (~80 LOC) | replaces airdate guessing |
| 4 | **Fribb/anime-lists** `anime-list-full.json` | offline id map + `season.tvdb` + `episode_offset.tvdb` | partial | med | **offline fallback** if ani.zip down |
| 5 | anime-relations (erengy) | curated sequel→numbering redirects | No (no rule for 199221) | low | legacy long-runners only |
| 6 | SeaDex `releases.moe` | curated *best* release per AniList id | No (series-level) | low | quality overlay, optional |
| 7 | anitomy family / our `relparser.py` | filename → ep#, season | No (no cour token) | — | needed only for un-eid'd Nyaa |

**Insight from Seanime/Hayase/Stremio:** there is no secret algorithm — they all
lean on the same ani.zip/Fribb data + AnimeTosho's eid tagging. The fix is to
**use the eid as the join key**, not to parse release names better.

## 3. Recommended architecture — resolve once, match by eid first

**Stage A — resolve `(AniList id, requested ep N)` → target descriptor** from the
ani.zip payload already fetched, looking up the entry whose **dict key == N**:
```
target = { eid, srel:(season, episodeNumber), abs:absoluteEpisodeNumber, cour:N, airdate }
candidates = { N, episodeNumber, absoluteEpisodeNumber }     # {1, 25, 83}
```
Fribb `anime-list-full.json` cached as offline fallback (`srel = season.tvdb, N + episode_offset.tvdb`).

**Stage B — discover + match:**
```
1. EID TIER-0 (authoritative, parser-free):
     GET feed.animetosho.org/json?eid=<target.eid>&only_tor=1  → ACCEPT directly.
     (resolves 199221 ep1 here, done.)
2. NUMBER TIER (un-eid'd / just-aired / Nyaa): parse title; accept if number ∈ candidates
     AND season/airdate-anchored (SxxEyy==srel | bare==abs | bare==N & this cour).
     Collision guard: reject a number that resolves to a different cour's space.
3. anime-relations redirect — legacy long-runners only, never primary.
4. BATCH: candidate ranges; extract one file by anidb_fid.
```
Prefer **eid over name parsing at every step.** SeaDex = optional quality overlay in
`select_release`, never on the critical path.

## 4. Sequenced plan (ordered, references our files)

1. **Re-key `map_anidb` to the ani.zip dict key** ([ingest.py:62-79](ingest.py#L62)):
   key `eid_to_ep`/`abs_to_ep`/`ep_airdate` by `int(k)` (the cour-relative request
   number); add `relnum_to_ep[(seasonNumber, episodeNumber)] = int(k)`. **~10-15 lines,
   no new dependency — unblocks 199221 today.**
2. **Use `relnum_to_ep` in `map_episode`** ([ingest.py:298-304](ingest.py#L298)):
   when an extracted `(es,ee)` matches the table, return its cour ep instead of failing
   the `1<=ee<=n` test. Eid branch ([ingest.py:286](ingest.py#L286)) now returns the right number.
3. **Add Tier-0 `?eid=` discovery** in `find_releases` ([ingest.py:151](ingest.py#L151)):
   build `ep_to_eid` inverse, query `?eid=<eid>` per requested ep, mark `_trusted`.
   Makes discovery robust for every split-cour/long-runner (early eids are buried deep
   in the reverse-chron `?aid=` pages today).
4. **Soften "Part N" in `relparser._SEASON_RX`** ([relparser.py:70](relparser.py#L70)):
   stop treating "Part N" as a TVDB season so Nyaa "Part 3 - 06" → ep 6, not season 3.
5. **Port Seanime offset / `usePartEpisodeNumber` math** to replace the airdate heuristic
   ([ingest.py:309](ingest.py#L309)) with deterministic candidate-set + collision guard.
6. **Cache Fribb `anime-list-full.json`** (daily) as offline fallback in `map_anidb`.
7. *(Optional)* SeaDex overlay in `select_release`; anime-relations pre-pass for legacy.

Steps 1-2 fix the canonical case with no new dependency; step 3 is the durable
robustness upgrade; 4-7 harden just-aired/Nyaa and add resilience.

## 5. Risks / guardrails

- **Just-aired window:** AnimeTosho hasn't eid-tagged releases for the first hours
  after air → Tier-0 thin, fall to number tier (Nyaa + `relnum_to_ep`/absolute). Keep `relparser`.
- **Silent wrong-episode (the cardinal sin):** a bare "- 06" from a Part-3 release could
  map to the wrong cour. The candidate-set + season/airdate anchor MUST reject any number
  resolving to a different cour's space.
- **ani.zip quirks:** duplicate finale rows exist (don't assume `len(episodes)==N` — use
  AniList `episodes`); let the real eid win on collision.
- **Single-aid assumption:** `az['mappings']['anidb_id']` is one aid for the whole entry;
  multi-cour entries split across AniDB aids can point at the wrong aid — `?eid=` sidesteps this.
