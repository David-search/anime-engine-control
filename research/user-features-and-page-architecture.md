# User features & page architecture (as built)

The application layer on top of the streaming pipeline
([streaming-pipeline-and-player.md](streaming-pipeline-and-player.md)): auth,
social (comments/likes), the watchlist, user-built **Tops** (public, rateable)
and **Collections** (private), and the page architecture after the player was
merged onto the anime page. Plus the observability wiring and the round of bug
fixes that shipped with it.

## Page architecture

| Route                          | Type   | Role |
|--------------------------------|--------|------|
| `/` | dynamic (SSR) | Spotlight carousel + trending/airing/popular rows + SEO block |
| `/anime/{id}/{slug}` | dynamic (SSR shell) | **the merged watch+detail page** — player at top, then meta, then rich detail + comments |
| `/watch/{slug}-{id}/{ep}` | redirect | 308 → `/anime/{id}?ep={ep}` (keeps old/shared links alive) |
| `/my-list` | client | watchlist + your Tops + your Collections, with create |
| `/list/{id}` | client | view/edit one list; rate public Tops |
| `/tops` | client | discover public community Tops |
| `/search`, `/genre/{slug}` | — | faceted browse |

### The player-on-page merge

The user chose "player on the anime page" over a separate watch route. The
detail page stays a **server component** (SEO: metadata, JSON-LD, synopsis);
the interactive watch experience is a client component,
`components/WatchPanel.tsx`, mounted at the top:

- Player pinned at top inside a **blurred-banner backdrop** (`.wp-backdrop`),
  centred 16:9 stage, controls + horizontal episode strip below.
- Picking an episode **swaps in place**: episode is client state; the URL
  `?ep=N` is updated via `history.replaceState` (no navigation, no server
  refetch). `?ep=` is read in an effect after mount (SSR renders ep 1 → no
  hydration mismatch).
- **Dead-source handling is visible** (no silent black screen): on a stall/
  error the watchdog auto-skips to the next source and shows
  `⚠ Source N didn't load — switched to Source M`; when all fail it states
  *No working source for this episode*.
- A slim **sticky identity bar** (`.dsticky`, poster + title) keeps context
  while scrolling the long page — the "I forgot which anime this is" fix.
  (Static on mobile to avoid overlapping the wrapped header.)

The hero was decluttered: the giant `-150px`-overlap banner header is gone
(it was also a mobile-overlap source); a compact `.dhead2` (poster + title +
chips + actions) sits below the player. The old standalone Episodes grid was
removed (the WatchPanel owns episodes). Unreleased titles render a
`.soon-hero` "Coming soon" panel instead of the player.

## Auth (recap)

Email/password + Google id-token, JWT in `Authorization: Bearer`. Frontend
`lib/auth.tsx` persists `{token, user}` in `localStorage`
(`anichan_token` / `anichan_user`) and exposes `useAuth()`. Client mutations go
through `lib/api.ts` `authJson()`, which attaches the bearer from the passed
token (or localStorage fallback). `optional_user` lets read endpoints stay
public while personalising when a token is present.

## Comments — wired + auth-gated

Backend (`/api/comments`) already existed; the frontend `Comments.tsx` had
never called it (pure local state — hence "comments don't work" **and** "I can
comment logged-out"). Now:

- Fetches real comments on mount (`getComments`), posts via `postComment`
  (bearer required; backend `current_user` 401s guests).
- The composer is **only rendered for signed-in users**; guests see a
  "Sign in to comment" CTA that opens the auth modal.
- AniList community reviews are still shown, clearly separated and read-only.

`Reactions.tsx` Like is now persisted via `/api/likes` (was localStorage);
guests are prompted to sign in.

## Watchlist, Tops & Collections

One backend model, three surfaces. New Mongo collections + indexes
(`db.py`): `watchlist`, `lists`, `list_ratings`.

### Watchlist ("My List")
Flat per-user bookmark set (`/api/watchlist`, denormalised `title`/`poster` so
the page renders without N catalog lookups). Toggled from the **Save** menu.

### Lists = Tops + Collections (`/api/lists`)
A single `lists` doc with a `kind` discriminator:

| kind | default visibility | ordered | rateable | purpose |
|------|--------------------|---------|----------|---------|
| `top` | **public** | yes (rank) | yes (1–5★ by others) | shareable ranking |
| `collection` | **private** | no | no | personal grouping (many allowed) |

Endpoints (all mutations `current_user` + **ownership-checked** via
`_own_list`): create / list-mine / public-browse / get-one (private invisible
to non-owners → 404) / patch (title, public) / delete / add-item (dedup,
cap 200) / remove-item / reorder / rate (public only, not your own; aggregate
`ratingAvg`/`ratingCount` cached on the doc for sorting). Cap 60 lists/user.

### Frontend
- `components/AddToList.tsx` — the unified **Save** menu on the anime page:
  watchlist toggle + check/uncheck against any of your lists + create a new
  list inline. Auth-gated (opens the modal for guests).
- `/my-list` — tabs for Watchlist / Tops / Collections + create.
- `/list/{id}` — grid; owner gets rename / public-toggle / per-item remove /
  (Tops) up-down reorder; non-owner of a public Top gets a star rater.
- `/tops` — public Tops ranked by rating.
- Header gains **Tops** + **My List** (nav, mobile menu, user menu).

## Bug fixes shipped alongside

| Bug | Root cause | Fix |
|-----|------------|-----|
| Mobile burger menu won't open | `.mobile-menu{display:none}` was defined **after** the `@media` rule that set `display:flex`, so it always won | Moved the base rule **before** the media query |
| Spotlight arrows overlap banner on mobile | arrows absolutely positioned at vertical-centre over the text (inline styles) | Moved to CSS classes; on ≤760px they drop to the bottom-left, dots bottom-right, hero gets bottom padding |
| "Coming soon" on RELEASING anime with episodes | `playable = len(curated_srcs) > 0` marked watchable shows as unplayable when our 5 hosts lag | Backend `playable = episodes > 0 or len(srcs) > 0`; frontend coming-soon = `status==NOT_YET_RELEASED \|\| epCount==0` (independent of the stale flag) |
| One Piece etc. missing DUB badge | `hasSub`/`hasDub` only set by the availability stamp, which hadn't run | Run `ingest availability` (also corrects coming-soon). Badge stays conservative (DUB only when known true) |
| source ordering | animedao (most stable) was source2 | promoted to **source1** |

> **Operational follow-up:** run `docker exec anime-backend python -m
> scripts.ingest availability` once on the server to stamp `playable/hasSub/
> hasDub/availEps` across the catalog — this is what makes the badges and
> coming-soon labels accurate. It shares the global semaphore, so it won't
> 429-storm live users.

## Observability (recap)

- **Telegram** (`telegram_logger.py`): INFO+ ships to the channel topic thread;
  startup, `🔎 search · "<q>"`, and watch (`/servers`, with the title) are
  logged. stdlib-only, daemon-thread queue.
- **Amplitude** (`lib/amplitude.ts`): `search`, `suggest_click`, `watch_play`
  (now fired from the in-page `WatchPanel`).

## Mobile correctness

The user flagged mobile overlaps as **very important**. Beyond the burger and
Spotlight fixes, the CSS carries `@media (max-width:760px)` and
`@media (max-width:400px)` blocks: the Save dropdown is **anchor-centred**
(`left:50%; translateX(-50%)`) so a `right:0` menu never bleeds off-screen; the
sticky identity bar sticks below a `--hdr-h` var (raised to 116px when the
header wraps) instead of overlapping it; the player control bars get
`min-width:0` + shrink on ≤400px; list grids go single-column and headers
stack. Verify on a 390px viewport after any UI change.

## Adversarial sweep (hardening)

A multi-agent sweep (mobile / no-auth / authed / backend / regression) ran
against the diff; confirmed findings were fixed:

- **No-auth dead-ends removed:** rating stars on `/list/{id}` are gated behind
  sign-in (guests get a "Sign in to rate" prompt, not a silent failure);
  `AddToList` and `Comments` re-open the auth modal on a `401` (expired
  session) via a typed `ApiError`; `/my-list` create surfaces an error instead
  of failing silently.
- **WatchPanel:** audio (SUB/DUB) buttons enable only while meta is loading,
  then only for audios that actually exist; clicking an already-failed source
  gives instant feedback instead of a dead 8-second wait.
- **Accepted (not fixed):** the backend list/rating endpoints have
  classic TOCTOU races (check-then-write on `MAX_LISTS`/`MAX_ITEMS`, rating
  re-aggregate) that would need MongoDB multi-doc **transactions** (a replica
  set we don't run) to close. Impact is a ±1 quota slip or a momentarily stale
  rating average under genuinely concurrent writes to the *same* list — benign
  at this scale. Revisit if the data store moves to a replica set.
