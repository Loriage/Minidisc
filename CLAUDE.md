# CLAUDE.md

Minidisc is an iPhone music player for Subsonic / OpenSubsonic servers (Navidrome first). It also plays
local folders the user references through Files, and integrates with ListenBrainz, Lidarr, AudioMuse-AI,
LRCLIB lyrics, Siri / App Intents and a yearly "Wrapped" recap.

## Toolchain facts that shape the code

| Setting | Value | Consequence |
|---|---|---|
| Platform | iOS 26.1+, iPhone only (`TARGETED_DEVICE_FAMILY = 1`), portrait | No iPad/macOS layouts to maintain (platform wrappers still exist, see below) |
| Swift | 6.0, `SWIFT_STRICT_CONCURRENCY = complete`, approachable concurrency | All concurrency diagnostics are on |
| `SWIFT_DEFAULT_ACTOR_ISOLATION` | **MainActor** | Every type is MainActor unless it says otherwise. Value types and helpers used from service actors **must be declared `nonisolated`** (`nonisolated struct …`, `nonisolated enum …`, `nonisolated static let` on `Logger`) |
| `SWIFT_TREAT_WARNINGS_AS_ERRORS` | YES | A warning fails the build. Don't leave unused vars or `try?` results that trigger warnings |
| `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY` | YES | Import the module you use in each file (e.g. `import SwiftSonic`, `import OSLog`) |
| Strings | String Catalogs, `STRING_CATALOG_GENERATE_SYMBOLS = YES` | Catalogs: `Localizable`, `LocalMusic` (table), `InfoPlist`, `AppShortcuts` |
| Dependency | `SwiftSonic` remote Swift package (`github.com/MathieuDubart/swiftsonic`) | The Subsonic API client. It is a separate MIT project with its own README/CHANGELOG/tests; change it only on purpose, upstream |

## Build and test

Inside Xcode, use the xcode-tools MCP commands. They are faster and pick up the active scheme:

- Build: `BuildProject` (scheme **Minidisc**)
- Quick type check of one file: `XcodeRefreshCodeIssuesInFile`
- Unit tests: the **Minidisc** scheme has no test action; run tests through the `MinidiscTests` scheme

From the command line (the project is `Minidisc.xcodeproj` at the repo root; there is no workspace):

```sh
# Build
xcodebuild build -project Minidisc.xcodeproj -scheme Minidisc \
  -destination 'platform=iOS Simulator,name=<any iPhone simulator>'

# Unit tests (MinidiscTests, Swift Testing)
xcodebuild test -project Minidisc.xcodeproj -scheme MinidiscTests \
  -destination 'platform=iOS Simulator,name=<any iPhone simulator>' \
  -only-testing:MinidiscTests

# One suite or test
  -only-testing:MinidiscTests/ServerServiceTests
  -only-testing:MinidiscTests/ServerServiceTests/addServer_firstServer_becomesActive()

```

Shared schemes: `Minidisc`, `MinidiscTests`, `MinidiscUITests`.

### UX verification (opt-in UI tests)

`MinidiscUITests/MinidiscUXVerificationTests` drives the real app against a local fake Subsonic server,
`Scripts/Testing/ux-fixture-server.py` (loopback port 18992). It needs a dedicated simulator named
**Minidisc UX Verification**. The tests skip any other device. Follow `Scripts/Testing/README.md`
exactly; it covers ad-hoc signing (needed for Keychain), the per-scenario catalogue modes and the
`rtk proxy` command prefix. Don't point that simulator at a real server.

## Folder map

```
Minidisc.xcodeproj
Minidisc/                      app target sources
  App/                         @main app, AppContainer (composition root), MinidiscRuntime, notification names
  AppIntents/                  App Intents / Siri / Shortcuts (AudioPlaybackIntent, MusicEntity)
  DesignSystem/                tokens (colors, spacing, typography), Components/, Theming/, Platform/ wrappers
                               README.md, MinidiscColors.md, Platform/CONVENTIONS.md: read before UI work
  Keychain/                    KeychainService + ServerCredentials (password, custom headers, AudioMuse token)
  Models/
    Domain/                    app value types: DisplayableSong, MinidiscError, UserFacingError, sorts, etc.
    Persistence/               SwiftData @Model types (ServerConfig, DownloadedTrack, CachedTrack, LibraryIndexModels…)
    Navigation/ Integrations/ ListenBrainz/ Recommendations/ Wrapped/
  ObservableState/             @Observable @MainActor state + settings (PlayerState, ServerState, *Settings)
  Services/
    Protocols/                 service contracts (PlayerServiceProtocol, LibraryServiceProtocol, …)
    Implementations/           most concrete services (PlayerService, ServerService, LibraryService,
                               MediaResolver, DownloadService, NowPlayingService, PlaylistService, …)
    Audio/                     AudioEngine protocol, AVPlayerEngine (dual-deck), gapless/crossfade planning
    LibraryIndex/              local-first catalogue: LibraryCatalog, LibraryIndexStore/Synchronizer, RemoteSource
    Networking/                ServerConnection, CustomHeadersTransport, background download transport
    Offline/                   offline browsing reader/library + removal planner
    Favorites/                 offline favourites store + automatic sync
    LocalMusic/                security-scoped local folder library
    Cache/ Diagnostics/ Intents/ Lidarr/ ListenBrainz/ Lyrics/ Recommendations/ Integrations/ Persistence/
  ViewModels/                  @Observable @MainActor screen view models
  Views/                       SwiftUI screens: Main/ (tabs, player, home, search), Browse/, Discover/,
                               Settings/, Onboarding/, LocalMusic/, Lidarr/, Wrapped/
  Utilities/                   Logger categories, formatting, HeaderValidator, PlatformImage, haptics
  *.xcstrings, Info.plist, Minidisc.entitlements, PrivacyInfo.xcprivacy, AppIntentVocabulary.plist
MinidiscTests/                 ~110 Swift Testing files (no XCTest)
MinidiscUITests/               XCTest UI tests incl. MinidiscUXVerificationTests
Scripts/Testing/               UX fixture server + instructions
```

## Architecture

### Composition root

There is no DI framework. `AppContainer` (`App/AppContainer.swift`) is a `@MainActor` class that
builds the entire service graph in one `init`, in dependency order, and owns long-lived lifecycle tasks.

- `MinidiscRuntime.shared` builds the container exactly once. **UI and headless App Intents share it**,
  so there is one player and one engine. It is registered with `AppDependencyManager`, and intents get it
  through `@Dependency private var runtime: MinidiscRuntime`.
- `MinidiscApp.makeContainer` runs the boot sequence. Order matters:
  `setup()` (wires PlayerService ↔ NowPlayingService) → `serverService.loadPersistedState()` →
  `networkMonitor.start` → `nowPlayingService.start()` → cache invalidation and migrations →
  `playerService.restoreSession()` → background sync and BGTask scheduling.
- The UI gets the container through `@Environment(\.appContainer)` (optional, `AppContainer?`). A few
  hot objects are also injected directly: `ArtworkImageCache`, `DominantColorExtractor`, `ToastService`,
  and the main `ModelContainer`.
- Views build their view models lazily, passing in only the services they need from the container:
  ```swift
  viewModel = AlbumDetailViewModel(albumId: albumId, libraryService: c.libraryService,
                                   downloadService: c.downloadService, toastService: c.toastService,
                                   serverState: c.serverState)
  ```
  View models depend on **narrow protocols** where they can (`any AlbumBrowsing`, not the whole
  `LibraryServiceProtocol`).

### Concurrency model

- **Services are `actor`s** (`PlayerService`, `ServerService`, `LibraryService`, `MediaResolver`,
  `NowPlayingService`, `DownloadService`, `LibraryCatalog`, `PlaybackSessionService`, …).
- **UI state is `@Observable @MainActor final class`** in `ObservableState/` (`PlayerState`,
  `ServerState`, settings) and `ViewModels/`. A service exposes its state as `nonisolated let state` and
  mutates it with `await MainActor.run { state.x = … }`.
- **Generation counters guard against stale async results.** This is the main defensive pattern in the
  codebase. `PlayerService` keeps `playbackGeneration`, `transportIntentGeneration`, `queueGeneration`,
  `prefetchGeneration` and others, and checks `isCurrentPlaybackIntent(...)` after every `await`. The
  server layer uses `ServerConnection.Version` (serverID + revision): long-lived clients cache on it, and
  reads re-check `activeConnectionVersion()` after awaiting so a server switch can't leak results.
  Engine callbacks carry an `AudioEnginePlaybackToken`. New async code in these areas must follow the
  same pattern.
- Cancellation is handled explicitly: `catch is CancellationError { throw CancellationError() }`,
  `try Task.checkCancellation()`, bounded `TaskGroup`s (typically 5 in flight).
- No Combine in new code. `NotificationCenter` is used for cross-screen events (names in
  `App/MinidiscNotifications.swift`, e.g. `.minidiscFavoritesChanged`, `.minidiscOfflineLibraryChanged`,
  `.minidiscNavigateToAlbum`). Post them from the main actor.

### Server layer

```
ServerState (@Observable)  ◀── ServerService (actor) ──▶ SwiftData ServerConfig + Keychain ServerCredentials
                                   │
                                   └─ activeConnection() → ServerConnection (process-local snapshot)
                                                            └─ makeSwiftSonicClient() → SwiftSonicClient
                                                               (CustomHeadersTransport adds proxy headers)
```

- `ServerService` owns server CRUD, the active server and connection testing (mapped to
  `ConnectionTestError`). Every activation or credential edit bumps the revision through
  `publishConnectionChange`, which then sets `ServerState.activeConnectionVersion`.
- Writes go to the Keychain first, then SwiftData, with rollback if the second step fails. Keep that
  ordering.
- `ServerConnection` contains secrets. Its `description` is redacted, and
  `authorizationHeaders(for:)` returns custom headers **only for the server's own origin**, so reverse
  proxy credentials never reach radio or artwork hosts. Always use it for any URL handed to AVPlayer or
  URLSession.
- `NavidromeCompatibility` runs on activation to detect Navidrome upgrades that change resource IDs,
  before any cache reads IDs.
- Online state: `NetworkMonitor` (NWPathMonitor) reduces path updates into a monotonic
  `NetworkPathEvent`, applies it to `ServerState`, and calls `playerService.handleNetworkPathChanged`
  directly. `ServerState.isOnline` is `network && !isOfflineModeEnabled`. Generation 0 is the launch
  baseline and recovery code ignores it.

### Library layer

```
ViewModels ─▶ LibraryService (actor, LibraryServiceProtocol = many small protocols)
                 ├─ LibraryCatalog (local-first) ─▶ LibraryIndexStore (separate SwiftData store)
                 │                                 └▶ LibraryIndexSynchronizer ─▶ SwiftSonicLibrarySource ─▶ ServerService
                 ├─ direct SwiftSonic calls (star, similar songs, artist info, scrobble) via a cached client
                 ├─ OfflineFavoritesStore / OfflineBrowsingReader fallbacks when offline or unreachable
                 └─ DownloadService, StatsService
```

- `LibraryServiceProtocol` combines narrow protocols (`AlbumBrowsing`, `ArtistBrowsing`,
  `PlaylistBrowsing`, `PlaybackQueueBuilding`, `PlaybackReporting`, …). Depend on the narrowest one.
- `LibraryCatalog` answers browse and search from the persisted index once a scan is complete, and only
  goes to the network otherwise. Automatic full index walks run only on an unmetered, unconstrained path
  (`ServerState.libraryIndexPreparationSnapshot`). Pull-to-refresh works on any online path.
- The library index lives in its own `ModelContainer` (`minidisc-library-index`, versioned schema and
  migration plan `LibraryIndexSchemaV3` / `LibraryIndexMigrationPlan`). It is a discardable cache, kept
  apart from user data. The playback session is also in its own store (`minidisc-session`) so frequent
  position saves stay out of the main observation graph. The main store schema is in
  `ModelContainer.minidisc`.
- Offline fallbacks only happen for network-class errors (`UserFacingError.noNetwork`,
  `.serverUnreachable`, `.contentUnavailableOffline`), never on cancellation.

### Player layer

```
UI / Intents / Remote commands
      │
      ▼
PlayerService (actor, ~4.7k lines: queue, shuffle/repeat, auto-extend, smart shuffle, instant mix,
      │        radio, session restore, network and audio-session recovery, crossfade/gapless prefetch,
      │        ReplayGain, scrobbling, stats)
      ├─▶ MediaResolver ── download ▶ stream cache ▶ remote stream (via ServerConnection)
      │                    (local folder files resolve through LocalMusicStore instead)
      ├─▶ AudioEngine protocol ◀─ AVPlayerEngine (dual-deck; delegate callbacks through AudioEngineBridge)
      ├─▶ PlayerState (@MainActor, read by the UI)
      ├─▶ NowPlayingService ─▶ NowPlayingCenterPresenter (MPNowPlayingInfoCenter / remote commands)
      ├─▶ PlaybackSessionService (queue + position persistence)
      └─▶ LibraryService (queue building, scrobble), ListenBrainzService, StatsService, DownloadService/cache
```

- **PlayerService never talks to SwiftSonic for media URLs.** It always goes through `MediaResolver`.
  `MediaResolver.availability` only reports `.missing` on a structured Subsonic `getSong` not-found
  response. Anything else is `.unknown`.
- `PlayerState` represents **user intent** (`playbackState`, queue, index), not the physical engine
  state. `PlayerService` tracks the engine separately (`activeEngineState`). `waitingReason` is
  presentation-only.
- The engine is synchronous and internally locked. Callbacks arrive on its own thread and are tagged
  with a playback token. A callback whose token isn't current is ignored.
- `MediaSource` cases: `.localFile`, `.downloaded`, `.cached`, `.stream(url, customHeaders:)`,
  `.liveStream`.
- Session persistence: positions are saved on a timer, on `scenePhase == .inactive`, and in full on
  `.background` (skipped while radio is playing).
- Settings changes are pushed into the actor explicitly: `replayGainSettingsDidChange()`,
  `crossfadeSettingsDidChange()`.

### Other subsystems

- **Downloads**: `DownloadService` (actor) with `BackgroundDownloadTransport` (a background URLSession)
  and `DownloadQueueController`. It publishes `progressStream`, which AppContainer mirrors into
  `DownloadActivityState`. Files live under `Documents/app.minidisc/downloads`.
- **Artwork**: `ArtworkImageCache` (thumb/hero tiers, `@thumb` / `@hero` filename suffixes). The cache
  version in `AppContainer.currentCoverArtCacheVersion` must be bumped when the tiering changes.
- **Background**: `BackgroundSyncCoordinator` deduplicates Wrapped and mood playlist sync between cold
  start and the BGProcessing task `app.minidisc.wrapped.monthly-update`.
- **Migrations** are one-shot, keyed by UserDefaults flags (`minidisc.*_vN`) in `AppContainer`
  extensions. Add a new flag; don't reuse an old one.

## Conventions

**Swift / concurrency**
- New services: an `actor` behind a protocol in `Services/Protocols/` when views or tests need to
  substitute it; add it to `AppContainer.init` in dependency order.
- New observable state or view models: `@Observable @MainActor final class`. Views keep the view model
  in `@State private var viewModel: XViewModel?` and create it from `container`.
- Data crossing actors must be `Sendable`, and value types must be declared `nonisolated` (see the
  default-isolation note above).
- Re-validate generation / connection version after every `await` that can race with a user action or
  a server switch.
- Errors: throw `MinidiscError` internally and map to `UserFacingError.from(error)` for display. Don't
  surface raw `localizedDescription`.

**Logging and privacy**
- Use the `Logger` categories in `Utilities/Logger+Minidisc.swift` (`Logger.player`, `.library`,
  `.server`, …). Add a new `nonisolated static let` there instead of creating ad-hoc loggers.
- Song/album IDs are logged `privacy: .public`. URLs, hosts and credentials are `.private` or omitted.
  Never log `ServerCredentials`, custom header values or full stream URLs. Diagnostics
  (`PlaybackDiagnostics`, `AudioEngineFailure`) store only domain/code pairs, never `userInfo`.
- Bracketed tags are used in log messages, e.g. `[TRANSITION]`, `[CLIENT]`, `[ExtMigration]`.

**UI / design system** (details in `Minidisc/DesignSystem/README.md` and `MinidiscColors.md`)
- No magic numbers: `MinidiscSpacing`, `MinidiscCornerRadius`, `.minidisc*` fonts from
  `MinidiscTypography`.
- Colors: semantic SwiftUI colors for text and backgrounds. `minidiscAccent` is for primary interactive
  elements only. New colors go into `Assets.xcassets` plus `MinidiscColors.md`.
- Plain SF Pro only (no `design: .rounded`) outside Wrapped and the generated-cover renderers. Favourites
  are hearts. Player, album, artist and local-collection pages are always dark (`ArtworkSurfacePalette`).
- Round buttons on those screens use `.buttonStyle(.minidiscCircle(...))` with `MinidiscControlSize`.
  Track rows have no "…" button; row actions live in the context menu and swipe actions.
- Design direction, decisions and deferred items: `docs/DesignOverhaul.md`.
- Cover art goes through `CoverArtCard` (or `CoverArtView` + `.minidiscCoverStyle` in flexible grids).
  Use `EmptyStateView` instead of `ContentUnavailableView` in screens. Reuse `SongRow`, `AlbumRow`,
  `PlayButton` and `SectionHeader`.
- Platform-specific APIs go behind `minidisc`-prefixed modifiers in `DesignSystem/Platform/` (see
  `CONVENTIONS.md`). Keep `#if os(...)` out of view bodies.
- User-facing strings are localized through the String Catalogs (`LocalizedStringResource` /
  `String(localized:)`; local-music strings use `table: "LocalMusic"`). Don't hard-code English in
  services that produce UI text.
- The DesignSystem README mentions an "MPL-2.0 header" for new components. No source file has one, so
  don't add it.

**Tests** (`MinidiscTests`)
- Use Swift Testing only: `import Testing`, `@testable import Minidisc`, `@Suite("Name") @MainActor struct …`,
  `@Test func subject_condition_expectation()`, `#expect`, `await #expect(throws:)`.
- Swift Testing runs tests in parallel, so each test creates its **own** in-memory stores:
  `ModelContainer.minidisc(inMemory: true)` (also `.libraryIndex` / `.session`), or
  `AppContainer(inMemory: true, userDefaults: <isolated suite>)`. Never share containers or
  `UserDefaults.standard` between tests.
- Fakes are hand-written next to the suite that first needs them (e.g. `MockKeychain` and
  `MockAudioStreamCache` in `ServerServiceTests.swift`, `MockServerService` in
  `OnboardingViewModelTests.swift`). Reuse an existing one before writing another. HTTP is stubbed at
  the SwiftSonic `HTTPTransport` level (`StubHTTPTransport`).
- Timing-sensitive player code takes injectable timing structs (`PlaybackNetworkRecoveryTiming`,
  `PlaybackAudioRecoveryTiming`) and an injectable `AudioEngine` / `AudioSessionControlling`. Use them
  in tests rather than sleeping.

**Git**
- Conventional-style commit subjects: `feat: …`, `fix: …`.
