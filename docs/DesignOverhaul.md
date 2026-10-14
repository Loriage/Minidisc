# Design overhaul (Narjo / Navibeat direction)

The first design pass moves Minidisc's player, album and artist screens closer to Narjo, with some
Navibeat details, while keeping the rest of the app visually coherent.

## Decisions

| Topic | Decision |
|---|---|
| Favourite iconography | Hearts everywhere (`heart` / `heart.fill`), replacing stars |
| Typography | Plain SF Pro (`design: .default`) for headings too; no SF Pro Rounded |
| Artwork-tinted screens | Always dark (player, album, artist, playlist), cover-derived tint, regardless of system appearance |
| Track rows | No trailing "…" button. Row shows number, title, featured artists, heart, duration. Actions move to the context menu and swipe |

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

## Deferred (not in the first pass)

- [ ] **Signal path sheet** on the player. Tapping the format line opens a panel describing the playback
  chain: source format → server stream (original or transcoded, from `StreamSettings`) → in-app
  processing (ReplayGain, crossfade / gapless) → output route (`AVAudioSession.currentRoute`, sample
  rate). Report only what the app can observe; never claim bit-perfect output. Reference: Narjo
  "Signal Path" screenshot.
- [ ] **Per-section actions on the artist page.** Each discography section header (Albums, Live Albums,
  Appears On, …) gets a sort label ("Newest First"), a play button and a shuffle button that act on
  that section's albums only. Reference: Narjo artist page.
