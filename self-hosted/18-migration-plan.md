# 18 · Migration plan: off ephemeral vast to persistent self-host

> Status: **plan** (2026-06-26). The system in docs
> [14](14-asbuilt-mapping.md)–[17](17-asbuilt-infra-ops.md) is **live and
> working** — the migration is not a rewrite, it's a *relocation of the one
> irreplaceable box*. The video origin (HLS cache + ingest pipeline + pre-cache +
> nginx + transmission + GPU NVENC) currently runs on **vast-canada-3
> (`159.48.242.1`)**, an **ephemeral rented RTX-4070 GPU node whose IP and public
> ports vanish on any re-rent/reboot/migration** ([17 § KEY RISK](17-asbuilt-infra-ops.md)).
> The app already plays ★ AniChan; this plan is about *owning the bytes* on
> durable, torrent-tolerant, DMCA-resilient infrastructure so a node swap stops
> being a fire drill.

This builds directly on the settled decisions in
[03-hosting-and-opsec.md](03-hosting-and-opsec.md) (mainstream object storage is
out; split clean-tier vs DMCA-ignored origin; CF is a shield not an origin),
[07-storage-design.md](07-storage-design.md) (local-FS HLS-at-rest, remux master
+ lazy ladder, LRU evict), [09-streaming-at-scale.md](09-streaming-at-scale.md)
(static-HLS + cache mesh, origin egress ≈ distinct-episodes not viewers), and
[12-cold-start-and-instant-playback.md](12-cold-start-and-instant-playback.md)
(pre-cache the slate is the #1 lever — and it's **parked** today precisely
because the test node is ephemeral).

---

## 0. Launch decision (chosen 2026-06-26)

After verifying current host pricing (research run `wf_8a6d7b02`) and settling the
encode model:

- **Encode model:** full bitrate ladder (1080 remux + 720 + 480), **store every
  quality**. The origin builds on **CPU** — `hls_build`'s `h264_nvenc`→`libx264`
  auto-fallback is already wired ([14](14-asbuilt-mapping.md)/[15](15-asbuilt-ingest-and-serving.md)),
  so **no GPU is required to launch**. A vast GPU build-farm (encode → ship) is a
  later optimization, not the launch shape.
- **Host line:** an **OffshoreDedicated "Streaming Dedicated"** box — NOT the plain
  dedicated line (that one is metered + "limited DMCA tolerance"; the *streaming*
  line is **unmetered** + media-complaint-tolerant). Bare Ubuntu 22, root, self-managed.
- **Lean start (~$155/mo):** 2× Xeon E5-2630v3 (16c), 48 GB RAM, **1× 8–16 TB HDD**,
  **1 Gbps unmetered**. Cheaply validates the whole model; LRU + popular slice +
  airing slate fit comfortably. Bump the disk to 16 TB if it's only a few dollars more.
- **Verified alternative:** **dmcaignored.com NL — 50 TB + 5 Gbps unmetered, $330/mo**
  — far more storage+bandwidth per dollar but a weaker CPU; the better pick *only if*
  encoding moves to a GPU farm and this box just serves.

| Model | Box | Why |
|---|---|---|
| **All-in-one** (download + CPU-encode + serve) | OffshoreDedicated streaming (more cores) | one box, simplest; cores do the encode |
| **Split** (GPU farm encodes → ships → serve) | dmcaignored 50 TB / 5 Gbps (cheap CPU) | encode is offboard; origin only stores+serves |

**Settled configurator choices:**
- **OS = Ubuntu 22.04** — lift-and-shift; avoids SELinux-vs-nginx + ffmpeg-codec
  friction (rules out AlmaLinux here).
- **HDD, not SSD, for the library** — HLS serving is sequential + RAM/Cloudflare-cached;
  the **uplink is the bottleneck, not disk IOPS**, and SSD at 50–84 TB costs 5–10×.
  Small SSD/NVMe only for OS + `cache_db` index.
- **RAID-6** once ≥4 disks (survives 2 failures; re-caching tens of TB is slow). One
  disk = no RAID, tolerable since the cache is reproducible.
- **Uplink = unmetered, 1 Gbps → 10/20 Gbps** as concurrency grows. **The uplink is
  the cost line, not the TB** (1 Gbps ≈ ~150–250 concurrent 1080p; Cloudflare in front
  multiplies it by serving repeat segments at the edge).

**Storage sizing — grow into it, don't pre-buy:**
- Measured **~1.4 GB/episode** full ladder (1080 877M + 720 349M + 480 175M + audio/subs);
  1080-only ≈ 0.86 GB.
- Whole popular slice (top ~1,000–2,000 titles) ≈ **42–84 TB**; the *entire* 10k catalog
  (~300k eps) ≈ **260–420 TB** — out of budget and unnecessary (power-law demand; the
  long tail streams from Miruro until promoted by demand).
- **Launch:** 8–16 TB hot cache (`CACHE_CAP_GB` ≈ disk − headroom) + LRU; add disks as
  the cache proves out.
- **Exclude long-runners:** skip self-host when **`availEps` > 100** (One Piece 1167,
  Conan 1204, Bleach 366, MHA 171…) — keyed on `availEps`, since `episodes` is null for
  open-ended shows. They fall back to Miruro.

**Stable address (the real resilience win):** front the origin with a **domain +
reverse proxy / Cloudflare** so a future host swap is a DNS change, not a `/set-env`
+ redeploy of `SELFHOST_ORIGIN`/`SELFHOST_INGEST_URL`.

---

## 1. What must move vs what can stay

The split is exactly the doc-03/doc-09 trust-tier line. **Nothing on
vast-canada-2 moves.** The migration touches one host.

| Component | Lives on | Migrate? | Why |
|---|---|---|---|
| `anime-frontend`, `anime-backend`, `mongodb`, `elasticsearch` | vast-canada-2 | **STAY** | the clean tier — catalog/search/watch API. Never touches video bytes; DMCA-safe; already durable. The backend just gets **three env values repointed**. |
| Mongo `selfhost_cache` (coverage read-index) | vast-canada-2 | **STAY** | denormalized; rebuilt from the origin's next `push_cache_state` ([16 §4](16-asbuilt-backend-frontend.md)). |
| **`/data/cache` HLS-at-rest (~63 GB)** | vast-canada-3 | **MOVE (stateful)** | the bytes. Rebuildable from torrents but expensive in re-ingest time; sync it to avoid a cold catalog on day 1. |
| **`/data/cache/index.db`** (`episodes` + `mapping_cache`) | vast-canada-3 | **MOVE (stateful)** | the LRU truth + the ani.zip→AniDB mapping persistence ([cache_db.py:18](cache_db.py#L18)). Without it the new origin re-fetches every map and loses `last_access` ordering. Cheap to copy; **also reconstructable** via `cache_db.py reindex` ([15 § index](15-asbuilt-ingest-and-serving.md)) if it doesn't come across. |
| `ingest.py` / `relparser.py` / `hls_build.py` / `ingest_api.py` / `precache.py` / `cache_db.py` / `run_ingest_api.sh` | vast-canada-3 | **MOVE (reproducible)** | pure code, mirrored read-only into `claude/self-hosted/`. `rsync` and go — no state. |
| nginx static config (`root /data/cache`) | vast-canada-3 | **MOVE (reproducible)** | trivial to recreate. |
| transmission state + `library/` | vast-canada-3 | **DROP** | in-flight torrents; nothing durable. A fresh transmission on the new box re-acquires on demand. |
| **GPU (NVENC ladder)** | vast-canada-3 RTX-4070 | **CONDITIONAL** | needed only for the 720/480 **encode ladder** and HEVC→H.264; the H.264 **master is a CPU remux** ([07 § Master](07-storage-design.md), [hls_build.py](hls_build.py)). See §4 — this is the one real architecture choice. |

**Bottom line:** one stateful blob (`/data/cache` + `index.db`), a handful of
reproducible scripts, and **one decision** (GPU vs CPU-only). The app tier is
inert during the move.

---

## 2. Host options — ranked

Requirements for the **origin**: (a) **torrent-tolerant + DMCA-ignored**
(acquisition + holding unlicensed video), (b) **cheap durable TB** (the cache
grows — §3), (c) **a fat unmetered port** (egress is the only cost that scales —
[09 § bandwidth math](09-streaming-at-scale.md)), (d) ideally a **GPU for NVENC**,
(e) **persistent** (the whole point). No single cheap box maxes all five, so the
recommendation is a **split origin**: cheap unmetered storage+serve VPS for the
bytes, GPU only where the encode actually needs it.

Prices are mid-2026, USD-equivalent, from the searches below — **confirm at
purchase, they drift.**

| Rank | Provider / product | Type | Torrent / DMCA | GPU? | Rough $/mo | Fit |
|---|---|---|---|---|---|---|
| **1** | **BuyVM / Frantech — Luxembourg KVM slice + Storage Slabs** | offshore VPS + block storage | torrent-tolerant, Roost-LU (free-speech jurisdiction); **unmetered 1 Gbps**, in-house 500 Gbps+ DDoS filtering ($3/IP) | **no** | **slice ~$7–30** (2–8 GB RAM) + **storage $5/TB** + DDoS $3 → **~$25–60/mo for a serve+store origin** | **★ primary serve/store origin.** Unmetered 1 Gbps + $5/TB durable storage is the cheapest "own the bytes" box on the market and survives indefinitely. No GPU — pair with #4 for encode, or go CPU-only (§4). |
| **2** | **FlokiNET — Romania dedicated** | offshore dedicated | DMCA-ignored, **unmetered bandwidth** (RO), 1 Tbps+ DDoS, anonymous signup | no (CPU dedi) | **~€99–150** entry; loaded NVMe boxes ~€485 | Strongest **single-box** offshore origin: real cores for CPU remux + the ladder, big NVMe, unmetered RO port. Pricier than BuyVM but one durable machine, anonymous, hardened jurisdiction. |
| **3** | **OffshoreDedicated / OffshoreServers / UltaHost / HostCay** (DMCA-ignored dedi pool) | offshore dedicated | DMCA-ignored; "streaming-optimized" tiers exist | varies (some GPU on request) | dedi **~$75–220**; streaming tiers from **~$219** | Mainstream-of-the-offshore-world. Use as a **fallback/second-source** if BuyVM stock or FlokiNET signup stalls. Vet torrent tolerance per-tier before spend. |
| **4** | **AnubizHost — offshore GPU dedicated** | offshore dedicated **+ GPU** | DMCA-ignored offshore | **YES** — RTX / Tesla, NVENC | **GPU from ~$149** | The **GPU-where-you-need-it** option. Only justified if §4 says keep NVENC. Could even stay **ephemeral-style** (rent the GPU *only* for batch ladder jobs) while the cheap unmetered box (#1/#2) holds + serves the bytes persistently. |
| 5 | OVH (tolerated-in-practice), 1984/Njal.la (Iceland privacy) | mainstream / privacy | grey — OVH tolerates, not DMCA-ignored; Iceland = legal-protection not raw bandwidth | OVH has GPU SKUs | OVH dedi ~$70+ | Keep as **reverse-proxy / shield** candidates ([03](03-hosting-and-opsec.md)), not as the torrenting origin. |

**Recommended pick:** **BuyVM Luxembourg (serve+store, persistent) as the origin**,
with **CPU-only remux + a CPU ladder** (§4) so **no GPU box is needed at all** in
the steady state. If wall-clock encode time on the airing slate proves too slow,
add **AnubizHost GPU on-demand** for batch ladder jobs only. This keeps the
monthly floor near **~$30–60** — an order of magnitude under the **$1000/mo
ceiling** ([self-hosted-direction memory]) — leaving headroom for the Phase-2
edge mesh (§6).

---

## 3. Storage sizing — from measured numbers

Anchored to the measured per-episode figures in
[07 § GB-per-episode](07-storage-design.md) and the **live ~63 GB** cache on the
node today ([17](17-asbuilt-infra-ops.md)).

Our packages are **richer than the doc-07 base ladder**: `hls_build` ships the
H.264 master + 720 + 480 + **every** audio rendition (sub+dub) + all subs/fonts
([hls_build.py](hls_build.py), [15 § serving](15-asbuilt-ingest-and-serving.md)).
Use a **planning figure of ~1.0–1.5 GB per fully-built episode** (1080p-class
master + 720/480 + multi-audio), versus the lean ~1.0 GB ladder in doc 07.

| Slice | Episodes | Per-ep | Subtotal |
|---|---|---|---|
| **Airing slate, kept hot** (precache top-20, ep 1 + newest 12 each → ~260 eps, [precache.py:63](precache.py#L63)) | ~260 | 1.25 GB | **~325 GB** |
| **On-demand long tail** (LRU-resident; what viewers actually open beyond the slate) | ~500 | 1.25 GB | **~625 GB** |
| **Curated/pinned** (must-keep classics, `pinned=1`, immune to evict [cache_db.py:140](cache_db.py#L140)) | ~150 | 1.25 GB | **~190 GB** |
| | | | **≈ 1.1 TB working set** |

**Recommendation:** provision **2 TB** durable storage, set **`CACHE_CAP_GB=1500`**
(vs `300` today). 2 TB on BuyVM Storage Slabs = **$10/mo** ($5/TB) — storage is
nearly free here, so the cap should be generous and the LRU lets cold tail churn.
Headroom to grow to 3–4 TB ($15–20/mo) as the catalog deepens. The cap is a
single env knob fed straight to `ingest.py evict` after every build
([15 § LRU](15-asbuilt-ingest-and-serving.md)) — raising it is non-disruptive.

> Why not "store everything"? A full pre-encode of a large catalog is 10s of TB
> ([09](09-streaming-at-scale.md) cites 2dhive ~19 TB). The LRU + pre-cache model
> is deliberately a **working-set** strategy: pre-position the predictable slate,
> cache the long tail on demand, evict cold. 2 TB comfortably covers that.

---

## 4. Architecture after migration

Same two-tier shape as [17](17-asbuilt-infra-ops.md), with the ephemeral GPU box
replaced by a **persistent offshore origin** and the origin made addressable by a
**stable domain** (not a churning IP:port).

```
                 USERS (browser)
                       │ https://anichan.net            (origin host/IP
                       ▼                                  never sent to client)
   ┌───────────────────────────────────┐
   │  vast-canada-2  (APP host) — UNCHANGED                 │
   │  anime-frontend · anime-backend · mongodb · es        │
   └──────────┬───────────────┬────────────────────────────┘
              │ trigger_ingest │ proxy HLS (master/seg/vtt/ass/fonts)
              │ GET /ingest    │ GET https://origin.<stable-domain>/{aid}/{ep}/{cat}/...
              ▼                ▼
   ┌───────────────────────────────────────────────────────┐
   │  PERSISTENT VIDEO ORIGIN  (BuyVM-LU or FlokiNET-RO)    │
   │  reverse-proxy / TLS terminator  ──►  nginx :8000      │  ← STABLE name
   │  ingest_api(tmux) · ingest.py · hls_build · transmission
   │  /data/cache (2 TB slab, CAP_GB=1500) · index.db       │
   │  precache.py  ── RE-ENABLED (--loop) ──►  _lo lane     │
   └───────────────────────────────────────────────────────┘
```

**Where the GPU is — and isn't, needed.** This is the load-bearing call:

| Build step | Cost | GPU? |
|---|---|---|
| **H.264 master** = `-c copy` remux to HLS | measured **~1 s, ~600× realtime** ([07 § Master](07-storage-design.md)) | **CPU — no GPU.** The common case (most fansub 1080p is H.264). |
| **720p / 480p ladder** | re-encode; NVENC is what the RTX-4070 accelerated | CPU `libx264 -preset veryfast/faster` works; slower (~real-time-ish per rung) but **acceptable offline** — the build is off the hot path, covered by Miruro ([12 §2](12-cold-start-and-instant-playback.md)). |
| **HEVC / 10-bit → H.264** | re-encode (browsers can't play raw HEVC) | CPU works; the select scorer already **prefers H.264 over HEVC** (+150, [14 §5](14-asbuilt-mapping.md)), so HEVC is the exception, not the rule. |

So: **CPU-only is viable** because (a) the master — the majority path — is a copy
remux with no encode at all, (b) the ladder + HEVC encodes run **offline in the
background** while Miruro covers the viewer, and (c) the selector already steers
toward H.264. `hls_build.py` must be switched from NVENC (`h264_nvenc`) to
`libx264` when no GPU is present — a codec-string change, **gate it on GPU
detection** so the same script runs on either box. **Keep the AnubizHost GPU
option in reserve** only if measured slate-encode wall-clock on the chosen
CPU box can't keep up with the airing cadence.

**Pre-cache re-enabled.** `precache.py` is **built, validated, and parked**
specifically because the test node is ephemeral
([15 § pre-cache](15-asbuilt-ingest-and-serving.md), [12](12-cold-start-and-instant-playback.md)).
On the persistent origin it runs `--loop` (every `PRECACHE_INTERVAL=1800`s),
feeding the `_lo` lane only — so the slate is warm before anyone opens it, the #1
cold-start lever finally turned on. Cron or a second tmux session.

**Static-HLS + edge model (doc 09) is unchanged** — origin serves immutable
files, egress-bound not CPU-bound (measured 5,677 req/s over loopback,
[15 § serving](15-asbuilt-ingest-and-serving.md)). The persistent origin is the
**origin-shield** target for the Phase-2 mesh (§6).

---

## 5. Cutover plan — ordered, low-risk, reversible

The guiding property: **the app keeps working off vast-canada-3 the entire time**
(every cross-host call is best-effort/try-except, [17 § four calls](17-asbuilt-infra-ops.md)),
so we stand up the new origin in parallel and flip at the end. Reversible at every
step until decommission.

**Phase A — stand up the new origin (no production impact)**
1. Provision the persistent box (BuyVM-LU slice + 2 TB slab, or FlokiNET-RO dedi).
   Attach/mount the slab at `/data`.
2. Install deps: python3, ffmpeg (with `libx264`; `h264_nvenc` only if GPU),
   transmission-daemon, nginx.
3. `rsync` the seven scripts from vast-canada-3 `/data/*.py` + `run_ingest_api.sh`.
   Set `h264_nvenc`→`libx264` in `hls_build.py` if CPU-only (or land the GPU-detect
   gate).
4. nginx: `root /data/cache; listen 8000;` (same as [17](17-asbuilt-infra-ops.md)).

**Phase B — make the origin address STABLE (kills the IP-churn fire drill)**
5. Point a **dedicated subdomain** at the origin — e.g.
   `origin.<throwaway-domain>` (a Njal.la anon domain, [03](03-hosting-and-opsec.md)).
   Put a **reverse-proxy / TLS terminator** in front (Caddy auto-TLS, or nginx +
   certbot; ideally a separate cheap throwaway VPS as the [03] origin-hiding proxy)
   listening on stable **`:443`** and proxying to the origin's nginx `:8000` and
   `ingest_api :8001`. Two stable hostnames or one host with two paths
   (`/hls/*` → nginx, `/ingest*` → ingest_api).
6. **The win:** `SELFHOST_ORIGIN`/`SELFHOST_INGEST_URL` now point at
   `https://origin.<domain>/...` — a **name, not `IP:VAST_TCP_PORT`**. A future
   node swap re-points DNS (seconds, no redeploy) instead of a `/set-env` +
   `/deploy-backend` every time the rented box churns. This is the single biggest
   resilience upgrade in the whole migration.

**Phase C — sync the stateful data**
7. Copy the cache + index over the wire:
   `rsync -a vast-canada-3:/data/cache/ neworigin:/data/cache/` (the ~63 GB; can
   run while the old node still serves).
8. Copy `index.db` (episodes + `mapping_cache`). If it doesn't transfer cleanly,
   run `python3 cache_db.py reindex` on the new box to rebuild `episodes` from the
   on-disk `master.m3u8` files ([15 § index](15-asbuilt-ingest-and-serving.md)) —
   the cache survives even if the DB doesn't.

**Phase D — launch + verify (still no flip)**
9. Write `run_ingest_api.sh` with the **same `INGEST_TOKEN`** (== backend
   `SELFHOST_INGEST_TOKEN`), `BACKEND_URL=http://70.30.158.46:43577`,
   `CACHE_CAP_GB=1500`. `tmux new -d -s ingestapi '/data/run_ingest_api.sh'`.
10. Off-host verify before touching prod ([17 runbook](17-asbuilt-infra-ops.md)):
    `curl -o /dev/null -w '%{http_code}\n' https://origin.<domain>/<aid>/<ep>/sub/master.m3u8`
    → `200`; `curl -s https://origin.<domain>/status` → queue JSON.

**Phase E — flip (one /set-env + one redeploy)**
11. `/set-env` the **three** backend values, then `/deploy-backend`
    ([17 § KEY RISK](17-asbuilt-infra-ops.md)):

    | Var | New value |
    |---|---|
    | `SELFHOST_ORIGIN` | `https://origin.<domain>` (or `/hls`) |
    | `SELFHOST_INGEST_URL` | `https://origin.<domain>/ingest` (or ingest subdomain) |
    | `SELFHOST_INGEST_TOKEN` | **unchanged** (same shared secret) |

    Because the token is unchanged and the cache was pre-synced, ★ AniChan
    coverage is intact the instant DNS+env line up.
12. Verify on prod: open a known-cached episode → ★ AniChan is Source 1; open a
    cold episode → it queues on the new origin and builds; watch
    `docker logs -f anime-backend` for `◆ cache-state` pushes from the new origin
    ([17 runbook](17-asbuilt-infra-ops.md)).

**Phase F — turn on pre-cache + decommission**
13. Start `precache.py --loop` on the new origin (the lever that was parked, §4).
14. Let it run a day; confirm coverage badges climb and the cache fills toward the
    cap. **Then release vast-canada-3.** Reverse path if anything regresses:
    re-point the three env values back at the old node (until released).

> **One-time risk window:** between flip and pre-cache warm-up, only the
> *pre-synced* episodes are ★ AniChan; everything else falls back to Miruro
> (graceful, no error) until re-ingested — exactly today's cold-open behavior.

---

## 6. CDN / edge — Phase 2

**When:** only when the origin's single unmetered port saturates. The math
([09 § bandwidth](09-streaming-at-scale.md)): 1080p ≈ 5 Mbps → **~160–180
concurrent streams per Gbps**. A BuyVM **1 Gbps** unmetered port therefore serves
**~150 concurrent 1080p viewers** before it's the bottleneck — and because origin
egress ≈ *distinct recently-played episodes × one cache-fill*, **not × viewers**,
real headroom is higher once an edge cache absorbs repeats. So edge is a
**later threshold, not day 1**: defer until sustained concurrency approaches
~100–150, or a popular new-release spike clips the port.

**What — owned mesh, never a mainstream CDN for the video.** Per
[03](03-hosting-and-opsec.md): Cloudflare/Fastly/etc. **DMCA-terminate
unlicensed video they host** (CF killed **21,218 R2 accounts** in H1 2025). The
edge for the *clean tier* can be CF (it forwards complaints, doesn't take down
proxied content — but it **leaks origin IP to complainants**, so the origin sits
behind our own reverse proxy from §5). For the **video**, build the doc-09 mesh
ourselves:

- 2–3 **cheap offshore unmetered VPS** as nginx `proxy_cache` edges
  (`slice` + `proxy_cache_lock` + `background_update`), each ~$7–15 on BuyVM-class
  hosts → **~$20–45/mo for the mesh**.
- One **origin-shield** in front of the real origin (so edges only ever hit the
  shield, never the holding box directly).
- GeoDNS / round-robin across the edges; the backend's `/api/watch/seg` proxy
  already hides the origin and is the natural `proxy_cache` insertion point
  ([15 § origin stays hidden](15-asbuilt-ingest-and-serving.md) flags
  "adding `proxy_cache` to `/api/watch/seg` is the documented next edge step").

Total even **with** a 3-node mesh + shield stays roughly **$80–150/mo** — still
far under the $1000 ceiling. The edge is the **primary scaling lever for
"thousands"** ([09](09-streaming-at-scale.md)), but it's pure Phase 2: the
persistent single origin (§4) is correct and sufficient for launch.

---

## 7. Risks + open decisions

| # | Risk / decision | Disposition |
|---|---|---|
| R1 | **DMCA takedown of the origin** | The origin is the *only* irreplaceable box ([03 survival playbook](03-hosting-and-opsec.md)). Mitigate: DMCA-ignored jurisdiction (Roost-LU / Romania), origin behind a reverse proxy so its real IP never reaches a complainant, **encrypted off-box backups** of `/data/cache` + `index.db` for fast redeploy. The cache is rebuildable from torrents — losing the box costs re-ingest time, not the catalog. |
| R2 | **IP churn** (the problem we're solving) | Solved structurally by §5 Phase B: a **stable domain + reverse proxy** means a node swap is a DNS change, not a redeploy. This is the single most important deliverable. |
| R3 | **GPU availability / NVENC** | **Decision (recommended): go CPU-only.** Master is a copy-remux (no encode); ladder/HEVC encode offline behind Miruro; selector prefers H.264. Keep AnubizHost GPU-on-demand in reserve *only if* measured slate wall-clock can't keep the airing cadence. Requires the `h264_nvenc`→`libx264` gate in `hls_build.py`. |
| R4 | **Cost ceiling (~$1000/mo)** | Comfortable. Origin **~$30–60/mo** (BuyVM slice + 2 TB slab + DDoS), or **~€99–150** (FlokiNET dedi). Even with a Phase-2 edge mesh, **~$80–150/mo** — a fraction of the ceiling. The ceiling only bites at true "thousands of concurrent" scale (15–25 Gbps, [09](09-streaming-at-scale.md)). |
| R5 | **Storage growth past the cap** | LRU bounds it ([15 § LRU](15-asbuilt-ingest-and-serving.md)); `CACHE_CAP_GB` is one env knob. At $5/TB raising the cap is nearly free; revisit at ~80% of 2 TB. |
| R6 | **Single-origin SPOF until Phase 2** | Accepted for launch. Miruro is the graceful fallback for every uncached/origin-down case (already wired, [16 §2.2](16-asbuilt-backend-frontend.md)) — an origin outage degrades to "no ★ AniChan", never a black screen. |

**Decisions the maintainer must make before spend:**
1. **Origin host:** BuyVM-LU split (cheapest, no GPU, **recommended**) **vs**
   FlokiNET-RO single dedi (one anonymous durable box, pricier) **vs** AnubizHost
   GPU dedi (only if keeping NVENC).
2. **GPU:** CPU-only (recommended) vs keep a GPU for the ladder. Gates the
   `hls_build.py` codec change and host choice (1).
3. **Stable-name domain + reverse-proxy host:** which anon domain (Njal.la) and
   whether the reverse proxy is a separate throwaway VPS (best for origin-hiding)
   or co-located (simpler, weaker hiding).
4. **Cache cap:** 1500 GB on 2 TB (recommended) vs larger if the catalog target is
   bigger than the §3 working set.
5. **Edge timing:** confirm the Phase-2 trigger threshold (~100–150 concurrent)
   and pre-pick the edge host class so the mesh is a known quantity before the
   first traffic spike.

---

**Sources (host options, mid-2026 — verify at purchase):**
[BuyVM Storage Slabs](https://buyvm.net/block-storage-slabs/) ·
[BuyVM KVM slices / unmetered + DDoS](https://buyvm.net/kvm-dedicated-server-slices/) ·
[BuyVM Luxembourg DC](https://buyvm.net/luxembourg-datacenter/) ·
[FlokiNET dedicated (IS/RO/FI)](https://flokinet.is/dedicated-server.php) ·
[FlokiNET VPS](https://flokinet.is/vps-server.php) ·
[AnubizHost GPU dedicated (NVENC)](https://anubizhost.com/en/cheap-dedicated-server-gpu) ·
[AnubizHost DMCA-ignored dedicated](https://anubizhost.com/en/dmca-ignored-dedicated-server) ·
[HostAdvice — DMCA-ignored hosting roundup](https://hostadvice.com/dmca-ignored-hosting/) ·
[UltaHost offshore dedicated](https://ultahost.com/dmca-ignored-dedicated-server)

**Cross-refs:** [03 hosting-and-opsec](03-hosting-and-opsec.md) ·
[07 storage-design](07-storage-design.md) ·
[09 streaming-at-scale](09-streaming-at-scale.md) ·
[12 cold-start](12-cold-start-and-instant-playback.md) ·
[14](14-asbuilt-mapping.md)–[17 as-built](17-asbuilt-infra-ops.md).
