# Design overhaul (Narjo / Navibeat direction)

The first design pass moves Minidisc's player, album and artist screens closer to Narjo, with some
Navibeat details, while keeping the rest of the app visually coherent.

## Decisions

| Topic | Decision |
|---|---|
| Favourite iconography | Hearts everywhere (`heart` / `heart.fill`), replacing stars |
| Typography | Plain SF Pro (`design: .default`) for headings too; no SF Pro Rounded |
| Artwork-tinted screens | Always dark (player, album, artist, playlist), cover-derived tint, regardless of system appearance |
| Track rows | No trailing "…" button. Row shows number, title, featured artists, heart, duration. Actions move to the context menu and swipe. Tapping the row plays; only the credits text opens artists |
| Action rows | Every round button in a row is the same size; Play only gets a stronger fill |
| Section spacing | One gap (`MinidiscSpacing.section`, 32pt) between page sections everywhere |
| Credit-only artists | Artists with nothing filed under them (e.g. *Bill Evans Trio*, filed under Bill Evans) show every album crediting them |
| Artist picker | Photos; split into In Your Library (tagged "N albums", counting filed + credited albums) and Not in Your Library |
| Artist discography | Vertical lists, expanded by default, every album shown, each section collapsible with its own Play / Shuffle |
| Lock screen | The favourite control stays a star: MediaPlayer exposes no glyph choice for `likeCommand` |

## Workstreams

- **W0 Foundations**: typography tokens, continuous corner radii, control sizes, shared dark artwork palette,
  circular action button, format badge, metadata chip, disc header, track-artist line, artist picker sheet.
- **W1 Data**: `DisplayableSong` carries contributing artists and audio properties (bit rate, bit depth,
  sample rate, channels); finer release categories; player exposes the current media source kind.
- **W2 Player**: shuffle / previous / play / next / repeat row, album title line, scrubber thumb,
  format and source line under the scrubber, circular buttons.
- **W3 Album**: header metadata line and chips, circular action row, disc headers, new track rows with
  tappable featured artists, Similar Artists shelf.
- **W4 Artist**: discography split into Albums, EPs, Singles, Live, Compilations, Appears On.
- **W6 Consistency sweep**: carry the row, heart and button changes to playlists, favourites, search,
  offline, local music; update the design-system docs.

## Iteration 1 (UI_Iterations_1.pdf)

Spacing token and right margins, equal action buttons, removed duplicate release block, leaner "Go to"
menus, row tap fix with a UX verification test, credited albums from the library index, picker redesign,
collapsible discography lists with per-section play, and genre / label album pages.

## Deferred (not in the first pass)

- [ ] **Signal path sheet** on the player. Tapping the format line opens a panel describing the playback
  chain: source format → server stream (original or transcoded, from `StreamSettings`) → in-app
  processing (ReplayGain, crossfade / gapless) → output route (`AVAudioSession.currentRoute`, sample
  rate). Report only what the app can observe; never claim bit-perfect output. Reference: Narjo
  "Signal Path" screenshot.
- [x] **Per-section actions on the artist page.** Play and Shuffle shipped in iteration 1.
- [ ] **Per-section sort label** ("Newest First") on artist discography headers; sections currently follow
  the global album sort.
