# Infrastructure — addresses, ports, credentials


**Three hosts.** The public domain `https://anichan.net` is served by an
**nginx TLS edge on web-goongle**, which reverse-proxies to the **app host
vast-canada-2** (containers + shared data stores); self-hosted video bytes
live on the **offshore HLS origin** (filled by a 6-node build farm). The app
port table is first; the edge, offshore, and build farm follow.

- **web-goongle** (`66.55.65.89`, ssh alias `web-goongle`) — public nginx
  TLS edge for `anichan.net` (and `goongle.net` — shared). See
  [§ Public edge](#public-edge--web-goongle).
- **vast-canada-2** (`70.30.158.46`, ssh alias `vast-canada-2`) — the app
  host. Runs `anime-frontend` + `anime-backend`, and shares `mongodb` /
  `elasticsearch` (+ goongle's own containers) on the external docker
  network **`goongle-network`** (they reach each other by container name).
  vast.ai maps the host's internal ports to public ports on `70.30.158.46`.
- **offshore** (`185.255.120.59`, ssh alias `offshore`) — HLS storage/origin.
  See [§ Self-host build farm](#self-host-build-farm-separate-fleet).

Use the **container name** (e.g. `mongodb:27017`) when on the same
docker network as the target; the **external public** port from anywhere
else; and **`https://anichan.net`** for the real public request path.

## Port map — host → external public on `70.30.158.46`

| Service        | Container        | Inner port              | Host port | External (`70.30.158.46`) |
|----------------|------------------|-------------------------|-----------|---------------------------|
| backend        | `anime-backend`  | 8000                    | 8008      | **43577**                 |
| frontend       | `anime-frontend` | 3000                    | 8003      | **43879**                 |
| MongoDB        | `mongodb`        | 27017 (mapped to `:8002`)| 8002     | **43829**                 |
| Elasticsearch  | `elasticsearch`  | 9200 (mapped to `:8005`)| 8005      | **43505**                 |
| SSH            | host             | 22                      | —         | **43730**                 |

Public service URLs:

- **site (public)** — `https://anichan.net` (via the web-goongle edge)
- backend (origin) — `http://70.30.158.46:43577` (behind the edge)
- frontend (origin) — `http://70.30.158.46:43879` (behind the edge)

The frontend reaches the backend two ways:

- **SSR (server→server, in-network):** `http://anime-backend:8000`
- **Browser (client→public):** `NEXT_PUBLIC_BACKEND_URL=https://anichan.net`
  — baked into the image at **build** time (it's a `NEXT_PUBLIC_*` var). Must be
  the public HTTPS origin; an `http://IP:port` here would be mixed-content-blocked.

## Public edge — web-goongle

`https://anichan.net` is **not** served by canada-2 directly. The public face is
an **nginx TLS edge on web-goongle** (`66.55.65.89`, ssh alias `web-goongle`,
root, **password** auth — `EDGE_PASSWORD` in `.env`). It terminates HTTPS
(Let's Encrypt `CN=anichan.net`) and reverse-proxies to canada-2's external ports:

| Public path   | upstream (canada-2)                            | nginx mode |
|---------------|------------------------------------------------|-----------|
| `/`           | `70.30.158.46:43879` (`anichan_app`, Next.js)  | buffered |
| `/api/watch/` | `70.30.158.46:43577` (`anichan_api`, FastAPI)  | **stream-through** — `proxy_buffering off`, Range, 120s (HLS) |
| `/api/`       | `70.30.158.46:43577` (`anichan_api`, FastAPI)  | buffered, 30s |

`:80 → 301 https`; `www → apex`. vhost `/etc/nginx/sites-enabled/anichan.net`;
upstreams `anichan_app` / `anichan_api` (`least_conn`, `keepalive 32`, `max_fails=32`).
The `/api/watch/` location is listed **before** `/api/` so HLS gets the
stream-through block.

⚠️ **Shared host** — web-goongle also serves `goongle.net` (and other vhosts).
Only ever edit the `anichan.net` vhost; scope any `nginx -t` / reload so you don't
disturb goongle. Certs renew via the host's existing certbot.

**SSH access — IMPORTANT (web-goongle is password-only, no SSH key installed):** plain
`ssh web-goongle` will **prompt for a password** (an agent can't answer that). To run edge
commands non-interactively, use **`sshpass`** (installed on the laptop) with `EDGE_PASSWORD`
from `.env`:

```bash
set -a && source .env && set +a
sshpass -p "$EDGE_PASSWORD" ssh -o StrictHostKeyChecking=no root@"$EDGE_HOST" 'nginx -t'
# edit the vhost (only the anichan.net one!), test, reload:
sshpass -p "$EDGE_PASSWORD" ssh root@"$EDGE_HOST" 'nano /etc/nginx/sites-enabled/anichan.net'   # or scp it up
sshpass -p "$EDGE_PASSWORD" ssh root@"$EDGE_HOST" 'nginx -t && systemctl reload nginx'
```

**Recommended one-time fix (needs your OK — it persists access on a shared host):** bootstrap
key auth so future sessions just `ssh web-goongle` keylessly —
`sshpass -p "$EDGE_PASSWORD" ssh-copy-id -i ~/.ssh/id_rsa.pub root@66.55.65.89` — then add
`IdentityFile ~/.ssh/id_rsa` under `Host web-goongle` in `~/.ssh/config`. (Claude was blocked
from doing this unprompted; run it yourself or tell Claude "yes, add the key".)

### Full vhost — recoverable copy of `/etc/nginx/sites-enabled/anichan.net`

Saved verbatim so the edge can be rebuilt if web-goongle is lost. (Note `X-Forwarded-For`
is set on every location — that's the real client IP source for any future rate-limiting.)

```nginx
upstream anichan_app {                 # Next.js frontend
    least_conn;
    server 70.30.158.46:43879 max_fails=32 fail_timeout=20s;
    keepalive 32;
}
upstream anichan_api {                 # FastAPI backend
    least_conn;
    server 70.30.158.46:43577 max_fails=32 fail_timeout=20s;
    keepalive 32;
}
server {
    listen 80;
    listen [::]:80;
    server_name anichan.net www.anichan.net;
    return 301 https://anichan.net$request_uri;
}
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name anichan.net www.anichan.net;
    ssl_certificate     /etc/letsencrypt/live/anichan.net/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/anichan.net/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;

    if ($host = 'www.anichan.net') { return 301 https://anichan.net$request_uri; }

    location / {
        proxy_pass http://anichan_app;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
    # HLS streaming — MUST come BEFORE /api/. Stream-through (no buffering), pass Range,
    # generous timeouts. Backend sets Cache-Control (segments immutable; m3u8 no-store).
    location /api/watch/ {
        proxy_pass http://anichan_api;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 120s;
        proxy_send_timeout 120s;
    }
    location /api/ {
        proxy_pass http://anichan_api;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_buffering on;
        proxy_read_timeout 30s;
    }
}
```

> ⚠️ For the future **Cloudflare** plan: this `anichan.net` vhost stays as the CF **origin**;
> `cdn.anichan.net` is **not** in this file (it's a separate DNS CNAME straight to Bunny). When
> CF fronts the app, switch the backend's client-IP source to `CF-Connecting-IP`.

## Shared infra — MongoDB + Elasticsearch

Same host, shared with a separate goongle project. AniChan uses its
**own** db (`anime_db`) and **own** index (`anime`); it does NOT touch
goongle's `rfp_db` or other indices. See [safety.md](safety.md).

| Service          | Container       | In-network        | External            | Auth                                          | AniChan uses        |
|------------------|-----------------|-------------------|---------------------|-----------------------------------------------|---------------------|
| MongoDB          | `mongodb`       | `mongodb:27017`   | `70.30.158.46:43829`| `admin` / `<stored in control .env on the server>` | db `anime_db`       |
| Elasticsearch 8.13 | `elasticsearch` | `elasticsearch:9200` | `70.30.158.46:43505`| `elastic` / `<stored in control .env on the server>` | index `anime`       |

**MongoDB `anime_db`** — 9 collections (indexes created on boot by
`app/db.py:ensure_indexes`):

| Collection | Usage | Key index |
|------------|-------|-----------|
| `anime` | catalog (AniList mirror + heavy fields); `_id` = AniList id | `idMal`, `genres`, `startDate.year`, `popularity` |
| `users` | auth accounts (email+password / Google `provider`) | `email` unique |
| `comments` | per-anime comments | `(anime_id, created desc)` |
| `likes` | per-anime likes | `(anime_id, user_id)` unique |
| `history` | resume-watching (ep + position per user/anime) | `(user_id, anime_id)` unique |
| `watchlist` | "My List" — flat bookmarks, denormalised title/poster | `(user_id, anime_id)` unique |
| `lists` | user lists: public ranked **tops** + private **collections** (`kind`) | `(user_id, updated)`, `(kind, public, ratingAvg)` |
| `list_ratings` | 1–5 ratings on public lists | `(list_id, user_id)` unique |
| `selfhost_cache` | self-host coverage marks (`_id`=anilistId → `cached.{sub,dub}`, `ep_titles`, `total_eps`); written by the build-farm `cache-state` callback | — |

**Elasticsearch `anime` index**: `search_as_you_type` suggest;
genres / tags / source / season facets; multilingual title search
(en + romaji + native).

In-network connection strings (what the on-server `.env` uses):

```
MONGO_URI=mongodb://admin:<stored in control .env on the server>@mongodb:27017/anime_db?authSource=admin
ELASTIC_URL=http://elasticsearch:9200
ELASTIC_USER=elastic
ELASTIC_PASSWORD=<stored in control .env on the server>
ELASTIC_INDEX=anime
```

## Credentials

- Mongo: `admin` / `<stored in control .env on the server>`, db `anime_db`
- Elasticsearch basic auth: `elastic` / `<stored in control .env on the server>`
- Backend / Frontend: no auth on the service itself (end-user auth is
  app-level, in `anime_db.users`)

The real Mongo/ES passwords live ONLY in the on-server control `.env`.
Never write them into a committed file — use the literal placeholder
`<stored in control .env on the server>`. See [secrets.md](secrets.md).

## Quick probes (off-server)

```bash
set -a && source .env && set +a

# ES doc count (the AniChan index only)
curl -sS -u "$ELASTIC_USER:$ELASTIC_PASSWORD" "$ELASTIC_URL/anime/_count"

# Mongo ping + catalog count
mongosh "$MONGO_URI" --eval 'db.adminCommand({ping:1}); db.anime.countDocuments()'

# Backend health + a real catalog read (note: every route is under /api)
curl -sS "http://70.30.158.46:43577/health"
curl -sS "http://70.30.158.46:43577/api/catalog/trending"
curl -sS "http://70.30.158.46:43577/api/search?q=frieren"

# Through the PUBLIC edge (what the browser actually hits)
curl -sS -o /dev/null -w '%{http_code}\n' "https://anichan.net/"
curl -sS "https://anichan.net/api/catalog/trending"

# Frontend origin up
curl -sS -o /dev/null -w '%{http_code}\n' "http://70.30.158.46:43879"
```

(Off-server probes use the **external** ports `43829` / `43505`; the
`$ELASTIC_URL` / `$MONGO_URI` in the control `.env` should point at
those public addresses, not the in-network names.)

## SSH

```bash
ssh -p 43730 root@70.30.158.46     # alias: vast-canada-2
```

Lands at `/root`. On-server deploy dirs:

- `/home/anime/backend/`  — Dockerfile, `docker-compose.yml` (with `build: .`), `.env`
- `/home/anime/frontend/` — Dockerfile, `docker-compose.yml` (with `build: .`), `.env`

Each `.env` is the **source of truth** for that service's runtime config.
See [deploy-loop.md](deploy-loop.md).

## Self-host build farm (separate fleet)

The app host above is pure catalog/search/proxy. The video bytes behind
"★ AniChan · self-hosted" come from a **separate 6-node GPU build farm** that
ships HLS to an offshore origin. This is operationally independent of the app —
**full runbook: [../../self-hosted/RUNBOOK.md](../../self-hosted/RUNBOOK.md).** The
addresses below are a quick reference; the live source of truth is [../../.env](../../.env)
(keys `NODE_CANADA2..7`, `EWEKA1..3_*`, `OFFSHORE_*`, `SELFHOST_*`). vast.ai
host:ports **rotate** as instances are rented/killed — keep `~/.ssh/config` and
`.env` in sync; these markdown values are a snapshot.

### Build nodes — 6× vast.ai GPU (ssh aliases `vast-canada-2..7`)

| Node | host:port (rotates) | Eweka acct | GPU | egress IP |
|------|---------------------|-----------|-----|-----------|
| canada-2 | `70.30.158.46:43730` | acct3 `e7e6…` | RTX 4060 Ti | 70.30.158.46 (also the app host) |
| canada-3 | `152.160.24.154:12173` | acct1 `d281…` | RTX A4000 | 152.160.24.154 |
| canada-4 | `162.239.74.119:15699` | acct1 `d281…` | RTX 4060 Ti | 162.239.74.119 |
| canada-5 | `38.64.28.7:28783` | acct2 `5edd…` | RTX 2060 (nzbget-flaky on big BD) | 38.64.28.7 |
| canada-6 | `192.165.134.28:13167` | acct2 `5edd…` | RTX 4070 Ti | 192.165.134.28 |
| canada-7 | `184.145.198.147:16656` | acct3 `e7e6…` | GTX 1070 Ti | 184.145.198.147 |

`canada-1` (`70.30.221.109:52572`) = **goongle-prod, NOT used** for the anime fill.

### Eweka Usenet — 3 accounts, 2 nodes each

Hard limit per account: **≈ 20 connections AND max 2 simultaneous source IPs** →
2 nodes/account (2 distinct egress IPs), **8 conns/node**. Host `news.eweka.nl:563`
(SSL NNTP). Accounts (creds in `.env` `EWEKA1..3_*`): acct1 `d281…` → canada-3+4,
acct2 `5edd…` → canada-5+6, acct3 `e7e6…` → canada-2+7. AnimeTosho is Omicron-only,
so a 2nd backbone doesn't help — dead torrents are recovered via live Nyaa instead.

### Offshore HLS origin (`offshore` ssh alias)

| | |
|---|---|
| Host | `185.255.120.59` (root, key auth; password in `.env` `OFFSHORE_PASSWORD`, rotate + disable pw auth) |
| Serves | nginx static `/srv/hls/{anilistId}/{ep}/sub/master.m3u8` (CORS `*`, Range/206) |
| Capacity | ~17 TB disk, **16 TB usable cap** (disk-guard stops farms if `/srv` < 1.5 TB free) |
| Backend wiring | canada-2 `/home/anime/backend/.env`: `SELFHOST_ORIGIN=http://185.255.120.59`, `SELFHOST_CACHE=1` |
| **CDN (front)** | **Bunny pull-zone `cdn.anichan.net`** (CNAME → `anichan.b-cdn.net`, Force SSL, token auth). `SELFHOST_CDN_BASE=https://cdn.anichan.net` + `SELFHOST_CDN_TOKEN_KEY` (secret). Heavy bytes serve **direct from Bunny, token-signed**; offshore is the pull origin. |
| **⚠️ Backup** | **none yet — single point of failure** (PENDING, see [STATE.md](../../STATE.md)) |

The heavy self-host bytes now serve **direct from the Bunny CDN** (token-signed); only the
KB-sized playlists proxy through canada-2's `/api/watch/m3u8`. Origin IP stays hidden (Bunny
pulls it). Coverage marks land in Mongo `anime_db.selfhost_cache` (gated by
`SELFHOST_INGEST_TOKEN`). Full design: [../../self-hosted/19-cdn-token-auth-and-hardening.md](../../self-hosted/19-cdn-token-auth-and-hardening.md).

#### offshore nginx — recoverable copy of `/etc/nginx/sites-enabled/hls`

Saved verbatim so the origin can be rebuilt (or stood up on the backup host). Bunny pulls
from this over HTTP; it serves `/srv/hls` static with the MIME types + CORS hls.js needs.

```nginx
# AniChan self-host HLS origin. Serves /srv/hls/{anilistId}/{ep}/{cat}/ (master.m3u8 + v*/a*/subs).
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    root /srv/hls;
    autoindex off;
    sendfile on; tcp_nopush on;
    types {
        application/vnd.apple.mpegurl m3u8;
        video/mp2t                    ts;
        video/iso.segment             m4s;
        text/vtt                      vtt;
        text/plain                    ass;
        application/json              json;
        font/ttf ttf; font/otf otf; font/woff woff; font/woff2 woff2;
    }
    default_type application/octet-stream;
    location = /healthz { return 200 "ok\n"; }
    location / {
        add_header Access-Control-Allow-Origin   "*" always;
        add_header Access-Control-Allow-Methods  "GET, HEAD, OPTIONS" always;
        add_header Access-Control-Allow-Headers  "Range, Origin, Accept" always;
        add_header Access-Control-Expose-Headers "Content-Length, Content-Range, Accept-Ranges" always;
        if ($request_method = OPTIONS) { return 204; }
        try_files $uri =404;
    }
}
```

### Quick farm probes

```bash
set -a && source .env && set +a
# per-node health (nzbget/farm/transmission up, shipped count, free disk)
for N in 2 3 4 5 6 7; do
  ssh vast-canada-$N 'echo "c'$N': nzbget=$(ps -C nzbget --no-headers|wc -l) \
    farm=$(pgrep -fc "[n]zb_farm.py") done=$(wc -l </data/done_node.jsonl) \
    free=$(df -h /data|tail -1|awk "{print \$4}")"'
done
# offshore: episodes shipped + disk used
ssh offshore 'find /srv/hls -name master.m3u8 | wc -l; du -sh /srv/hls; df -h /srv | tail -1'
```
