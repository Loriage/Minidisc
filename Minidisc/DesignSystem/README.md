# Minidisc Design System

A lightweight, token-based design system for SwiftUI. The goal is visual consistency across all screens with no magic numbers in view code.

---

## Colors

Defined in two places:

| Source | What lives there |
|--------|-----------------|
| `Assets.xcassets` | `MinidiscAccent`, `MinidiscAccentSecondary` — Xcode auto-generates `Color.minidiscAccent` etc. with light/dark variants |
| `MinidiscColors.swift` | `minidiscAccentText`, `minidiscCoverShadow`, `minidiscCoverBorder` — pure Swift constants |

See `MinidiscColors.md` for the full palette table, WCAG contrast notes, and usage rules.

**Critical rules:**
- `minidiscAccent` is for **primary interactive elements only** (play button, scrubber, active toggles, tappable artist name). Never on body copy or captions.
- All text and backgrounds use SwiftUI semantic colors (`Color.primary`, `.secondary`, `Color(.systemBackground)`, etc.).
- Never add custom colors without updating `MinidiscColors.md`.

---

## Spacing

Use `MinidiscSpacing` constants everywhere. Never write a literal `CGFloat` for spacing.

```swift
enum MinidiscSpacing {
    static let xs:    CGFloat = 4
    static let s:     CGFloat = 8
    static let m:     CGFloat = 12
    static let l:     CGFloat = 16   // standard padding
    static let xl:    CGFloat = 20
    static let xxl:   CGFloat = 24
    static let xxxl:  CGFloat = 32
    static let xxxxl: CGFloat = 48
}
```

---

## Corner Radii

```swift
enum MinidiscCornerRadius {
    static let xs:       CGFloat = 4
    static let s:        CGFloat = 6
    static let standard: CGFloat = 8   // list thumbnails, buttons
    static let large:    CGFloat = 12  // cover art in detail views, mini-player card
    static let pill:     CGFloat = 999 // capsule buttons
}
```

---

## Typography

All font styles are `Font` extensions defined in `MinidiscTypography.swift`. Use them instead of `.font(.title2)` + `.fontWeight(.semibold)` pairs.

| Token | Spec | Usage |
|-------|------|-------|
| `.minidiscPlayerTitle` | `.title`, rounded, bold | Track title in FullPlayerView |
| `.minidiscDetailTitle` | `.title2`, rounded, semibold | Album/playlist name in detail header |
| `.minidiscSectionTitle` | `.headline`, rounded, semibold | Section headers in scroll views |
| `.minidiscBody` | `.body` | Body copy |
| `.minidiscCellTitle` | `.callout`, medium | Primary text in list cells |
| `.minidiscCellSubtitle` | `.subheadline` | Secondary text in list cells (artist name, owner) |
| `.minidiscCaption` | `.caption` | Metadata (year, track count, duration) |
| `.minidiscCaption2` | `.caption2` | Smallest text (footnotes, timestamps) |

---

## Cover Art

### `CoverArtCard`

The standard wrapper for any cover art thumbnail. Handles async loading, 1:1 clip, and adaptive shadow (light) / border (dark).

```swift
// Standard list thumbnail
CoverArtCard(id: album.coverArt ?? album.id, size: 56)

// Large detail header (album, playlist)
CoverArtCard(id: album.coverArt ?? album.id, size: 220, cornerRadius: MinidiscCornerRadius.large)

// Mini-player
CoverArtCard(id: track.coverArt ?? track.id, size: 44)
```

**Do not** use `CoverArtView` directly in views and manually apply `.clipShape` + `.shadow`. Always prefer `CoverArtCard`.

**Exception**: flexible-width contexts (2-column grids) where the size is determined by geometry. Use `CoverArtView` + `.minidiscCoverStyle(cornerRadius:)` + `GeometryReader` in that case.

### `.minidiscCoverStyle(cornerRadius:)`

The view modifier that `CoverArtCard` applies internally. It clips the view and adds:
- A drop shadow in light mode
- A 1pt white-8% border in dark mode (shadows are invisible against dark backgrounds)

---

## Components

### Immersive playlist details

PlaylistArtworkHeader displays the original square cover, including locally rendered playlist titles,
and fades its lower half into a dark colour sampled from the image's bottom edge. It deliberately uses
CoverArtView without the thumbnail border or shadow so the artwork can extend to the screen edges.

PlaylistDetailMetadata groups the title, owner and update date. PlaylistPlaybackControls centres
Shuffle, Play and Download and stacks them at accessibility text sizes. The track count and total
duration belong below the song list, in PlaylistTrackSummary. SongRow's menu mode keeps playback
and the menu as separate touch targets and permits two text lines at accessibility sizes.

PlaylistFeaturedArtistsShelf uses the same MinidiscShelf, carousel title, 104-point portraits and
ArtistPortraitCell as Similar Artists on an artist page. Artwork lookup and navigation stay with
their respective screens.

The isolated playlist artwork scenarios in Scripts/Testing exercise these components with real
cover loading, cover replacement and large text; see that directory's README for reproduction.

### `SongRow`

Standard track cell for album and playlist detail screens.

```swift
// Album context — shows track number
SongRow(song: song, index: index + 1)

// Playlist / search context — shows thumbnail
SongRow(song: song, index: index + 1, showCoverArt: true)

// With download badge
SongRow(song: song, index: index + 1, isDownloaded: true)

// Currently playing (accent title)
SongRow(song: song, index: index + 1, isCurrentTrack: true)
```

### `AlbumRow`

Flat list cell — 56pt thumbnail, name, artist, year.

```swift
AlbumRow(
    albumId: album.id,
    name: album.name,
    artist: album.artist,
    year: album.year,
    coverArtId: album.coverArt
)
```

Use in flat lists (search results, etc.). For grids, use `CoverArtView + minidiscCoverStyle` directly.

### `ArtistRow`

List cell with an initials avatar (gradient circle). Does not attempt to load a cover art image — Subsonic servers rarely supply artist artwork.

```swift
ArtistRow(artist: artist)
```

### `PlayButton`

The primary "Play" action button — orange capsule, white label, `play.fill` icon.

```swift
PlayButton(action: {
    Task { try? await playerService.play(tracks: songs, startIndex: 0) }
}, isDisabled: songs.isEmpty)
```

Pairs with an icon-only download/cancel button in the same `HStack`.

### `EmptyStateView`

Used for error states, empty libraries, and empty search. Replace all `ContentUnavailableView` usages with this.

```swift
// Error state with retry
EmptyStateView(
    systemImage: "exclamationmark.triangle",
    title: "Unable to Load Album",
    subtitle: error.localizedDescription,
    action: .init(label: "Retry") { Task { await vm.load() } }
)

// Empty state, no action
EmptyStateView(
    systemImage: "music.mic",
    title: "No Artists",
    subtitle: "Your library appears to be empty."
)
```

### `SectionHeader`

SF Pro Rounded semibold header for use inside scroll views (not inside `List`/`Section` headers).

```swift
SectionHeader("Recent Albums")
```

---

## Adding a new component

1. Create `DesignSystem/Components/MyComponent.swift` with the MPL-2.0 header.
2. Use only design system tokens (no magic numbers, no hardcoded colors).
3. Add a `#Preview` block.
4. Document it in this file under **Components**.

## Adding a new color

1. Add the color set to `Assets.xcassets` with both Any and Dark Appearance variants.
2. Add a row to the palette table in `MinidiscColors.md` with WCAG notes and permitted uses.
3. Do **not** add a manual `Color` extension — Xcode generates `Color.<assetName>` automatically.
