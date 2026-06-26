# 03 · Hosting & opsec — where the bytes can live

The crux. The content is unlicensed, so this is not an infra problem, it's a
*where-can-the-bytes-physically-sit-without-being-deleted* problem. Findings
below are from a 112-agent cited research pass (25 claims verified 3-vote, 0
killed) unless marked as a lead.

## Settled: mainstream object storage is OUT for video

By the providers' **own legal text**:
- **Backblaze (B2 in scope)** — registers a DMCA agent, removes infringing
  material, **terminates repeat infringers**.
- **Wasabi** — DMCA removal; AUP allows removal **without notice** + immediate
  termination for known-illegal content.
- **Cloudflare R2/Stream/Pages/Workers** — removes what it hosts. Hard proof:
  **Cloudflare terminated 21,218 R2 accounts for streaming piracy in H1 2025**
  (DMCA actions on hosted content rose 1,394 → 54,357).

→ **B2/Wasabi/R2/CF-Stream = images, metadata, posters ONLY. Never the video.**
(Matches the Discord: Doujiva uses R2 *for manga images*; everyone agreed video
needs DMCA-ignored hosts.)

## Cloudflare's real role: shield, not origin

- **Safe as a pass-through proxy/CDN/shield** — Cloudflare *"cannot remove
  content it does not host."* For proxied content it **forwards the complaint to
  the operator and hands the origin IP to the hosting provider** — it doesn't
  take the stream down at its edge. (Italian courts had to *legally compel* CF to
  disconnect a pirate site; abuse reports alone don't.)
- **So:** CF in front of the clean tier = fine. The **video origin must be
  DMCA-ignored**, and because **CF leaks your origin IP to complainants**, you
  also hide the origin behind **your own reverse proxy** (a cheap throwaway VPS
  that proxies to the real box). This is the Discord's *"Cloudflare doesn't count,
  they forward"* — true, and handled by the reverse proxy.

## Other verified opsec constraints

- **Datacenter IPs get blocked upstream** (DLHD, MegaUp block all DC IPs incl. CF
  Workers) → scrapers route through **residential proxies**. *Self-hosting dodges
  this entirely* — your own origin isn't fighting an upstream IP block.
- **Signed playback URLs** (RS256 JWT, ≤24h) stop token-less scrapers stealing
  your streams — anti-theft, orthogonal to hosting safety.

## Host leads (NOT yet verified — vet in the hosting pass)

No concrete DMCA-ignored host was among the 25 verified claims — these are leads
from forum/blog sources, to confirm for **torrent-tolerance + real $/mo + fleet
viability**:

| Lead | Type | Notes |
|------|------|-------|
| **FlokiNET** | offshore VPS+dedi (Iceland/Romania/Finland) | LowEndTalk; privacy/offshore reputation |
| **1984 Hosting** | Iceland privacy host | LowEndTalk |
| **Njal.la** | privacy domains + VPS (anon) | LowEndTalk; also for the domain |
| **BuyVM / Frantech** | cheap **block-storage slabs**, lax | Discord (Doujiva waiting on stock) |
| **OVH** | mainstream but **tolerated-in-practice** | Discord (Hentai Ocean) |

Taxonomy (dieg.info): "bulletproof"/offshore = jurisdictions with **no
MLAT/extradition** (Iceland, Moldova, Seychelles, NL-offshore, RU). The trade-off
is reliability + price + how aggressively they cave under pressure.

## Survival playbook (from takedown history)

- **Origin = the only thing you can't fake.** AnimeHeaven died when its origin
  host complied with a Crunchyroll DMCA. Choose the origin carefully; keep
  **encrypted off-box backups** so you can redeploy fast.
- **Rotate the cheap stuff:** multiple **domains/mirrors** (ANIMO + animotvslash
  run `.ru`/`.org`/`.to` alts), Cloudflare in front, throwaway reverse-proxy VPS.
- **Split blast radius:** clean tier (catalog/API/frontend) on a normal host can
  be DMCA'd without losing the library; the video origin is isolated + rotatable.
- **Expect DDoS + IP/domain blocks** as routine (the Discord is full of it).

## The split architecture (the whole point)

```
            ┌─────────── Cloudflare (shield/CDN, forwards complaints) ───────────┐
 users ───► │  CLEAN TIER (normal host): catalog/API/frontend/metadata/images   │
            └──────────────────────────────┬───────────────────────────────────┘
                                            │ signed playback URL
                          ┌─────────────────▼─────────────────┐
                          │  reverse-proxy VPS (hides origin)  │  ← throwaway
                          └─────────────────┬─────────────────┘
                          ┌─────────────────▼─────────────────┐
                          │  VIDEO ORIGIN — DMCA-ignored host  │  ← the only
                          │  acquire (torrent/NZB) + cache +   │     irreplaceable
                          │  transcode + serve HLS             │     box
                          └────────────────────────────────────┘
```
