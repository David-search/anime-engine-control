# Kodik — investigation & verdict (dead end for us)

*Investigated June 2026 from `vast-canada-2`. User asked: "is the Kodik player
available, what audio/subs does it have, can we lay an English dub on top?"
Short answer: **double dead-end for an English audience** — Russian-only audio
AND the API is geo-blocked from our server. Use [Miruro](post-hianime-landscape-and-miruro.md) instead.*

Context for "lay dub on top": user's sites of interest were
`old.yummyani.me` and `jut-su.net` — both Russian sites that embed **Kodik**.

---

## 1. Availability from our server (fragile)

| Host | Result from vast-canada-2 | Meaning |
|---|---|---|
| `kodikapi.com` (the real API) | **http=000** | blocked / unreachable (geo-fenced to CIS) |
| `kodik-api.com` (a mirror) | http=500 | connects but errors |
| `kodik.info`, `kodik.cc` | **000** | blocked |
| `kodikplayer.com` (player CDN) | **200** | only the CDN responds |

Same pattern as the AllAnime IP-block ([allanime-api-blocked] in memory): the
**API host is unreachable**, only the video CDN answers. We could not call the
Kodik search/resolve API server-side even if we wanted to.

## 2. What it actually carries — **Russian audio only**

Per the Kodik API doc, every track is one of:
- `type: "voice"` → **Russian dub**
- `type: "subtitles"` → **Russian soft-subs**

There is **no original-Japanese or English** track entry. The *subtitle*
releases do run **original Japanese audio** underneath (with Russian soft-subs
on top) — that's the one structurally-useful bit.

`yummyani.me` and `jut-su.net` both just embed Kodik with Russian dubbing-team
audio. They are Russian-market sites end to end.

## 3. "Lay an English dub/sub on top of Kodik" — why it fails

- **English subs:** *theoretically* possible — take a Kodik **subtitle release
  (Japanese audio)**, extract its m3u8, play in our own player, attach our own
  English `.vtt`. But that requires (a) reverse-engineering Kodik's stream
  extraction (the embed is a Russian-UI black box), **and** (b) sourcing +
  time-syncing English subtitle files for the whole catalog ourselves — Kodik
  gives you none. That's an entire content pipeline, to end up with
  Japanese-audio + English-subs… which English-native sources already hand us
  directly.
- **English dub:** **impossible** to overlay. A dub *replaces* the audio track;
  you'd need synced English audio files we don't have, and the iframe embed
  can't be injected into anyway.

## 4. Verdict

Kodik is excellent **for a Russian audience** and useless for ours, on two
independent counts (Russian-only audio + API geo-blocked). **Do not integrate.**
The real need — a reliable English **sub + dub** source to replace flaky
MegaPlay — is answered by **Miruro's pipe**, which returns direct m3u8 +
English VTT (sub *and* dub) and is reachable from our server. See
[post-hianime-landscape-and-miruro.md](post-hianime-landscape-and-miruro.md).
