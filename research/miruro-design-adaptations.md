# Miruro design → AniChan adaptations

*From a study of miruro.to (the leading 2026 free anime site). Miruro's live site
is a Vite/React SPA (empty server HTML), so the design DNA was read from its
open-source frontend [Miruro-no-kuon/Miruro](https://github.com/Miruro-no-kuon/Miruro)
(styled-components/TS) + UX reviews. Reviewers call it "Aniwave but prettier… the
best UI, way ahead of the old clunky sites." That reputation comes from a small set
of repeatable decisions — captured here.*

## Miruro's design system (the load-bearing facts)
- **Palette:** near-black `#080808` base, `#141414` / `#222` surfaces, card `#181818`,
  text `#e8e8e8`, muted `#696969`, hairline borders `rgba(245,245,245,0.1)`. **ONE**
  accent for every active/hover/selected state. One radius token (`0.3rem`) everywhere.
- **Cards:** poster ≈ **2:3** (133:184), `padding-top` ratio trick for **zero CLS**;
  hover = `translateY(-10px)` lift + image `brightness(0.5)` + centered play icon fade-in.
- **Grid:** `repeat(auto-fill, minmax(10rem,1fr))`, `gap:2rem` → `1rem` down breakpoints.
- **Hero:** Swiper, `24rem`, 5s autoplay, **diagonal** gradient `linear-gradient(45deg,#080808,transparent 60%)`,
  content bottom-left, "WATCH NOW" bottom-right (collapses to a circle on mobile).
- **Watch page:** two-column ≥1000px — **player left, episode list right**, list height
  synced to player height; stacks on mobile.
- **Episode list:** 3 view modes (number-grid / titled-list / thumbnail-list), a range
  `<select>` ("1–100"), in-list search, **watched-state** coloring, auto-scroll current into view.
- **Server selector:** a **Sub/Dub × server matrix**, active cell = filled accent pill.
- **Nav:** fixed, `backdrop-filter: blur(10px)`, `/`-to-focus search, debounced dropdown
  of 5 mini-poster results with keyboard nav + "View all →".
- **Skeletons:** same 2:3 ratio as the real card (no reflow); pulse + popIn.
- **Micro-interactions:** hover `scale(1.05)`, active `scale(0.95)`, `slideUp`/`popIn` on mount.

## Prioritized adaptations for AniChan (high-impact, low-effort first)
1. **2:3 card, lift-and-dim hover + play overlay.** `aspect-[2/3] rounded-xl`, group hover
   `-translate-y-2` + `img brightness-50` + centered play icon fade-in. Reserve the box up
   front → zero layout shift. *(Biggest "premium" signal.)*
2. **Strict token system: one dark scale + accents.** `--bg:#0a0a0c --surface:#141418
   --surface-2:#1d1d22 --border:rgba(255,255,255,.08) --text:#e8e8e8 --muted:#7a7a82`,
   **pink `#ff5fa2` = primary/active**, **purple `#a855f7` = secondary/hover** (pink→purple
   gradient on hero CTA + logo = our identity vs Miruro's single accent). No one-off colors.
3. **On-poster sub/dub + episode-count badges.** Top-left CC "SUB" pill (pink-tint) + stacked
   mic "DUB" pill (purple-tint); bottom-right `▦ 12` ep-count pill; `bg-black/60 backdrop-blur`.
4. **Hero: diagonal gradient, bottom-left text, bottom-right CTA.** `bg-gradient-to-tr from-bg
   via-bg/70 to-transparent`, `h-[24rem]`, gradient pink→purple "Watch Now". *(Carousel already shipped.)*
5. **Two-column watch page: player left, episode list right (height-synced), stack on mobile.**
6. **Episode list: view-mode toggle + range select + in-list search + watched states**, persisted
   in localStorage by anime id; auto-scroll current into view. *(Highest-utility for 1000-ep shows.)*
7. **Server selector as a labeled grid, not a raw dropdown** — active = filled pink pill, "if a
   server doesn't work try another" helper. *(We already expose source1..sourceN; style as a grid.)*
8. **Sticky translucent header + `/`-focusable search + live mini-poster dropdown.** *(Reuse our suggest.)*
9. **Skeletons matching the final 2:3/16:9 shapes** (pulse) so nothing reflows when data lands.
10. **Home as tabbed grid (Trending/Popular/Top-rated) + right "Top Airing / Upcoming" sidebar.**
11. **Status dots + per-anime AniList accent on titles** (ongoing `#aaff00`, completed `#00aaff`,
    upcoming `#ffa500`, cancelled `#ff0000`).
12. **One `<MetaRow>`** (`★ rating · ▦ eps · 📅 date · type`, muted bold, inline icons) reused everywhere.
13. **Universal micro-interactions:** `hover:scale-105 active:scale-95`, `slideUp`/`popIn` mount
    (stagger by index), respect `prefers-reduced-motion`.
14. **Persist everything in localStorage by anime id** — last episode, watched-set, source/lang,
    layout, last-visited → a **"Continue Watching"** rail. High value, zero backend (fits our local model).
15. **Max width `105rem` centered, `4.5rem` top pad for the sticky nav, responsive gaps.**

**Do-first six (close most of the gap):** #1 card hover, #3 badges, #2 tokens, #4 hero gradient,
#9 skeletons, #13 micro-interactions. **Next tier (functional heart):** #5/#6/#7 watch page.
**Be AniChan not a clone:** lean into the **pink→purple gradient** + a larger `rounded-xl` radius.

Sources: [Miruro source](https://github.com/Miruro-no-kuon/Miruro) ·
[everythingmoe review](https://everythingmoe.com/review/503932134) ·
[AlternativeTo](https://alternativeto.net/software/miruro/)
