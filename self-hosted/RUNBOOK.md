# Self-host build farm — RUNBOOK (as-built, operational)

The operational source of truth for the **self-host video pipeline**: a fleet of
rented vast.ai GPU nodes that acquire anime from Usenet/torrents, encode to HLS,
and ship to an offshore origin the backend auto-serves. Design rationale lives in
`01..18-*.md` (numbered as-built notes); this file is **how to run it day-to-day**.

All credentials are in the control-plane **`../.env`** (gitignored). This doc names
the keys; never paste real secrets here.

---

## 1. What it is (one screen)

```
 dump_resolver.py            nzb_farm.py (per node, /data/run_node.sh)        offshore (185.255.120.59)
 ───────────────             ──────────────────────────────────────          ───────────────────────
 AniList top-N anime  ──►   resolve todo  ──►  download  ──► encode ──► ship ──► nginx static /srv/hls
 (offline AnimeTosho dump   (todo_node.jsonl)   NZBGet(Eweka)  Y-mode   rsync     {aid}/{ep}/sub/master.m3u8
  + LIVE Nyaa fallback)      NZB-first,         /transmission  NVENC    /ssh      (CORS *, Range/206)
                             torrent fallback                  H.264               │
                                                                                   ▼
                                                          backend (canada-2) live-probes SELFHOST_ORIGIN
                                                          per request → auto-serves "AniChan · self-hosted"
                                                          source1 + marks selfhost_cache (coverage badges)
```

- **Ship-and-delete**: nodes never STORE — each ep is download → encode → ship → `rm`.
  Disk must stay bounded; accumulation = a bug (see §7).
- **Auto-serve, zero per-anime config**: the moment an ep lands on offshore, the
  backend offers it (`/api/watch/servers?anilistId=&ep=` → source1
  "AniChan · self-hosted (ad-free)"). The `selfhost_cache` Mongo collection holds
  coverage marks for the catalog "cached" badges.

---

## 2. Topology — 6 nodes, 3 Eweka accounts (`../.env`)

Eweka HARD LIMIT per account: **~20 connections AND max 2 simultaneous source IPs**.
So **2 build nodes per account** (2 distinct egress IPs), **8 connections/node**.

| Eweka acct | nodes (ssh alias) | GPU | egress IP |
|---|---|---|---|
| acct1 `EWEKA1` (d281…) | canada-3 + canada-4 | A4000 / 4060 Ti | 152.160.24.154 / 162.239.74.119 |
| acct2 `EWEKA2` (5edd…) | canada-5 + canada-6 | 2060 / 4070 Ti | 38.64.28.7 / 192.165.134.28 |
| acct3 `EWEKA3` (e7e6…) | canada-2 + canada-7 | 4060 Ti / GTX 1070 Ti | 70.30.158.46 (shared host w/ app) / 184.145.198.147 |

- **canada-2** is also the app/prod host (frontend+backend+mongo+ES). Using it as a
  build node is fine (no real traffic yet), but keep an eye on its load.
- **canada-1** (`70.30.221.109`) = goongle-prod, ~40 GB free — **NOT used** for the fill.
- vast **SSH HostName ≠ egress IP** (NAT). Confirm the IP Eweka sees with
  `curl -s https://api.ipify.org` on the box, not the ssh config. Co-located nodes
  (same vast host) share one egress IP → count as 1 IP (safe).
- Offshore origin `185.255.120.59` (`OFFSHORE_*`), ~17 TB, **16 TB usable cap**
  ≈ the top-427 anime (<100 eps). Disk-guard stops farms if `/srv` < 1.5 TB free.

---

## 3. The pipeline scripts (`self-hosted/`, mirrored to each node `/data/`)

| Script | Role |
|---|---|
| `dump_resolver.py` | resolve anime → `todo` items. Offline AnimeTosho dump (`at_index.sqlite`) OR `--live` (current Nyaa+AnimeTosho with LIVE seeders). `resolve_anime_live()` is also called inline by the farm (§6). |
| `nzb_farm.py` | the farm orchestrator: read `todo_node.jsonl`, download (NZBGet→Eweka primary, transmission fallback, **live-fallback** §6), Y-mode encode, ship, mark. Bounded encode queue (MAXQ) = ship-and-delete backpressure. |
| `nzb_acquire.py` | NZB download via `nzbget -c /data/nzbget.conf`; moves the video out of nzbget churn + `rmtree`s the dir on success. |
| `ingest.py` | shared lib: `find_releases` (live Nyaa RSS sorted by seeders + AnimeTosho feed), `select_release`, `download` (transmission), `download_batch_multi` (extract eps from a pack). |
| `hls_build.py` | Y-mode encode: remux 1080 8-bit H.264 (copy) + NVENC 720/480 ladder; JP+EN audio. AV1/Hi10P/HEVC need full re-encode (slow) — avoided in resolve (§7). |
| `run_node.sh` | per-node supervisor: disk-guard subshell + `while true: python3 nzb_farm.py` (infinite retry). Sources `/data/callback.env` + `/data/node.env`. |
| `nzbget_supervisor.sh` | keeps nzbget alive: `pidof nzbget || { rm -f nzbget.lock; nzbget -D; }`. The **lock-rm is critical** (stale lock blocks restart). |
| `ensure_up.sh` | cron watchdog: recreates the `farm`/`nzbget`/`trd` tmux sessions if any died (reboot/crash). |
| `partition.py` | round-robin anime → N disjoint `todo_q{i}.jsonl` (no racing, no locking). |

Per-node layout: `/data/{nzb_farm.py,…,nzbget.conf,callback.env,todo_node.jsonl,done_node.jsonl}`,
`/data/nzbget/{completed,inter,queue,tmp}`, `/data/library` (transmission), `/data/staging`.

---

## 4. Autonomy (runs unattended; the laptop can be off)

Each node runs **3 tmux sessions** + a **cron watchdog**:
- `farm` → `run_node.sh` (the fill; `while true` retries nzb_farm forever).
- `nzbget` → `nzbget_supervisor.sh` (revives nzbget + clears stale lock).
- `trd` → transmission supervisor (`pgrep -x transmission-da || transmission-daemon --download-dir /data/library`).
- cron: `*/2 * * * * /data/ensure_up.sh` + `@reboot sleep 30 && /data/ensure_up.sh`.

NZBGet `ContinuePartial=yes` + `FlushQueue=yes` → a killed nzbget **resumes**, never
re-downloads from scratch. Mongo marking + offshore 16 TB disk-guard are autonomous.
**Self-heal proven**: an 8-hour unattended run shipped 510 eps with no input.

---

## 5. Day-to-day operations

**Status sweep (all nodes):**
```bash
for N in 2 3 4 5 6 7; do
  ssh -o ClearAllForwardings=yes -o ControlPath=none vast-canada-$N \
   'echo "c'$N': nzbget=$(ps -C nzbget --no-headers|wc -l) farm=$(pgrep -fc "[n]zb_farm.py") \
    tr=$(pidof transmission-daemon|wc -w) done=$(wc -l </data/done_node.jsonl) \
    free=$(df -h /data|tail -1|awk "{print \$4}") \
    live=$(grep -ciE "\[LIVE (single|pack)\]" /data/run_node.log)"'
done
ssh -o StrictHostKeyChecking=no root@185.255.120.59 'find /srv/hls -name master.m3u8|wc -l; du -sh /srv/hls; df -h /srv|tail -1'
ssh vast-canada-2 'docker exec anime-backend python3 -c "import os,pymongo;print(pymongo.MongoClient(os.environ[\"MONGO_URI\"])[\"anime_db\"].selfhost_cache.count_documents({}))"'
```

**Restart a dead daemon (per node):**
```bash
# farm:   tmux new-session -d -s farm   "bash /data/run_node.sh >>/data/run_node.log 2>&1"
# nzbget: tmux new-session -d -s nzbget "bash /data/nzbget_supervisor.sh"
# trd:    tmux new-session -d -s trd    "while true; do pgrep -x transmission-da >/dev/null || transmission-daemon --download-dir /data/library; sleep 10; done"
```

**Provision a NEW node** (replacing a killed/bad one):
1. **NVENC-test FIRST** (catches bad instances before wasting setup):
   `ffmpeg -hide_banner -loglevel error -f lavfi -i testsrc2=size=640x360:rate=10 -t1 -c:v h264_nvenc -f null -`
   → empty output = good; any output = skip the instance.
2. `apt install -y nzbget transmission-daemon par2 unrar p7zip-full tmux rsync python3-pip cron; pip3 install requests`
3. scp the bundle (`*.py run_node.sh nzbget_supervisor.sh ensure_up.sh callback.env`),
   a per-account `nzbget.conf` (swap `Server1.Username/Password`, `Connections=8`,
   `DupeCheck=no`, `DirectWrite=no`), and the node's `todo_q{i}.jsonl`→`todo_node.jsonl`.
4. mkdir `/data/nzbget/{completed,inter,queue,tmp,nzb,scripts} /data/library`; start the 3 tmux
   sessions + cron; gen `/root/.ssh/id_ed25519`, add its pubkey to offshore `authorized_keys`.
5. **Re-seed `done_node.jsonl`** from offshore so it skips already-shipped eps (no double work):
   `ssh offshore 'find /srv/hls -name master.m3u8' | sed -E 's#/srv/hls/([0-9]+)/([0-9]+)/sub/master.m3u8#{"aid": \1, "ep": \2, "dub": false}#' > done_node.jsonl`

**Mongo / offshore reset (start fill over):** drop `selfhost_cache` (delete_many), `rm -rf /srv/hls/*`
on offshore, clear each node's `/data/{staging,library,nzbget/{completed,inter,tmp,queue}}` + `done_node.jsonl`.
Shipped content lives ONLY on offshore + `selfhost_cache`; cleaning node working-dirs is always safe.

---

## 6. Dead-torrent recovery (live Nyaa fallback)

The catalog was resolved from the **frozen AnimeTosho dump** → stale seeder data →
~all per-episode dump-torrents are dead now, though the same anime are **alive on Nyaa
as well-seeded COMPLETE packs**. AnimeTosho only *indexes* Nyaa (same info_hash), and a
2nd Usenet backbone can't help (AnimeTosho is Omicron-only). **Fix = live torrents:**
`nzb_farm.acquire()` calls `live_fallback(it)` when a dump-torrent dies →
`dump_resolver.resolve_anime_live(aid)` (cached per-anime, serialized) → seeded pack/single →
`download_batch_multi` extracts the ep. Validated in prod (e.g. Hajime no Ippo ep61).
Restarting a farm re-processes past failures too. Marker lines: `[live-resolve] → [LIVE pack] → [dl ok]`.

Bug guarded: `ingest.download()` returns `(None,None)` on a dead torrent (does NOT raise) —
`acquire` uses `if p: return p, tid` so the failure falls through to `live_fallback`.

---

## 7. Known issues & gotchas

- **Disk fill from heavy packs** (the big one): live-recovery prefers complete packs, often
  **BD AV1/Opus/Hi10P** — AV1 has **no HW decode** on these GPUs → 40-min software re-encodes +
  broken audio → ship FAILs → files never delete → disk fills. Fix in `resolve_anime_live`:
  **skip AV1** (`\bav1\b`) + cap **per_mb ≤ 3000**. If a node still creeps low, clean it (safe):
  `rm -rf /data/nzbget/{completed,inter,tmp}/* /data/staging/* /data/library/*; transmission-remote -t all --remove-and-delete`.
- **Disk-guard is crude**: `run_node.sh` pkills the farm at <50 G but the infinite-loop + cron
  watchdog restart it (defeating the guard). The AV1/size fix keeps disk bounded so it rarely
  fires; long-term, make the monitor PAUSE downloads (not kill encode). Reactive clean <40 G works.
- **canada-5 nzbget is flaky** — crashes on huge BD/HEVC packs. `pidof/pgrep` unreliable there;
  use `ps -C nzbget --no-headers|wc -l`. Deep-clear if stuck:
  `tmux kill-session -t nzbget; pkill -9 -x nzbget; rm -f /data/nzbget/nzbget.lock; rm -rf /data/nzbget/queue/*; tmux new-session -d -s nzbget "bash /data/nzbget_supervisor.sh"`.
- **NVENC bad-driver instances**: an RTX 5060 Ti needs driver 590+/API 13.1; driver 595.58.03 was
  broken for Turing; some 2070s have NVENC disabled (vGPU). ALWAYS NVENC-test before provisioning.
- **vast bandwidth is metered both ways** (per-GB, host-set) — pick low `inet_down_cost` hosts or
  RunPod (free transfer) for download-heavy nodes. (We've moved ~2 TB.)
- **Nodes ship by raw IP, not the `offshore` alias.** `run_node.sh` ships to
  `root@185.255.120.59` directly (the `offshore` ssh alias is only on the laptop). Each node's
  pubkey lives in offshore `/root/.ssh/authorized_keys` (13 keys currently); nginx static-serves
  `/srv/hls/{aid}/{ep}/sub/{master.m3u8, v0, a0=jpn, a1=eng, subs}` (dual-audio + subs).
- **Public serving path = backend proxy, not direct.** Users hit
  `https://anichan.net/api/watch/m3u8?url=…185.255.120.59…` — the **web-goongle** nginx edge
  (`66.55.65.89`, shared w/ goongle.net, stream-through `location /api/watch/`) → backend on
  canada-2 → proxies the offshore origin (IP hidden, SSRF-guarded). Offshore *should* serve
  directly someday (HTTPS + cdn subdomain) to offload canada-2 bandwidth — **not done yet** (the gap).
- **On-open auto-cache is DISABLED (2026-06-26).** The backend's `trigger_ingest` →
  `{SELFHOST_INGEST_URL}/ingest` "cache-on-open" path is commented out in `watch.py` — caching is
  now a deliberate build-farm step, not viewer-triggered. (`SELFHOST_INGEST_URL` was
  `159.48.242.1:35147`, a rotated build-node receiver, now down — moot while disabled.) The
  **active** path is the node→backend `cache-state` callback (`CALLBACK_URL` + `SELFHOST_INGEST_TOKEN`),
  which now **merges** coverage so a partial/resumed run never regresses prior episodes.
- **Self-match footgun**: NEVER `pkill -f` a pattern containing `nzb_farm.py` / `run_node.sh` /
  `nzbget -c` if that string also appears elsewhere in the same ssh command — it kills your own
  shell. Use `tmux kill-session` + `pidof|xargs kill` instead.
- **Eweka "502 Too many connections"** = an account exceeded ~20 conns (likely a duplicate nzbget
  on one of its 2 nodes). Keep `Server1.Connections=8`; ensure one nzbget per node.

---

## 8. Progress model & ETA

- Target ≈ **6–7 k episodes** (top-427 anime; ~9–10 TB, under the 16 TB cap).
- Measured ~**60 eps/hr** across 6 nodes (feed/encode-bound). ETA ≈ **~4 days** for a full fill.
- Failures cluster in torrent-only titles → recovered by the live fallback (§6), not lost.
- Resume: `done_node.jsonl` (per node) + offshore are the ground truth; the farm skips done eps.

Related memory: `eweka-multiaccount-scaling-and-usenet-providers`, `dead-torrent-live-fallback`,
`buildfarm-nvenc-provisioning`, `back-catalog-acquisition-reality`, `self-hosted-direction`.
