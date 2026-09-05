# Playback and offline continuity

## Observable behavior

- Preparing a queue, buffering and reconnecting have explicit waiting states. Brief waits remain hidden for 700 ms; the reconnection message requires an actual recovery attempt, not a preventive watchdog marker. Pause and Next remain meaningful during recovery. A late queue preparation cannot override a newer transport command.
- A failed stream is checked against Navidrome before treating the song as removed. Only a structured `getSong`/`getPlaylist` not-found response confirms deletion; connectivity failures and proxy HTTP 404 responses do not.
- Opening or starting an old playlist revalidates its content. A deleted playlist displays one explanation and retains its downloaded music. An unavailable queue advances through a bounded number of songs and stops safely when none are playable.
- Home displays its last saved feed by server while offline. During a cold load, one slow section does not hold back the others. Pull-to-refresh applies its result together to preserve scroll layout.
- The player queue shows the actual upcoming songs directly below its playback modes, without an Up Next heading, footer or an album presented as their source.
- Failed playlist edits keep the editor and its draft open. Retrying after a partial save is safe. Explicit playback, favorite and download actions surface failures.
- The selected tab and search text survive scene restoration. Changing server clears navigation paths that reference the previous server. Download and playback controls have explicit accessibility labels.

## Durable downloads

`DownloadQueueController` owns a JSON journal containing metadata and collection ownership, without stream URLs, passwords or request headers. A collection's missing tracks are saved together before any transfer is submitted. Requests use the current matching server connection.

`BackgroundDownloadTransport` uses one named background `URLSession`. Its delegate synchronously moves each completed file into a persistent inbox and saves a small receipt before returning. Audio validation, optional faststart remuxing and SwiftData persistence happen before acknowledging that receipt. Relaunch can replay a received file if finalization was interrupted.

Failed jobs remain visible and can be retried with a new transfer identifier, so late callbacks from an older attempt cannot affect the replacement. Cancellation is persisted before stopping the system task. Collection ownership prevents cancellation of a transfer still needed elsewhere. Intent tokens prevent deletion during preparation or finalization from recreating a removed collection.

The Downloads screen shows queued, waiting, downloading, processing and failed jobs, with progress, Retry and Cancel. Standalone songs without an album remain accessible. Downloading an album does not disable playback.

iOS controls background scheduling. Force-quitting an app prevents its background relaunch; journaled work can resume when the app is opened again. Validation and remuxing that cannot finish within a background execution window remain replayable from the inbox.

## Local diagnostics

The support report includes bounded playback startup and interruption metrics, Home data-ready latency, cache-load counts and download completion/failure counts for the current process. It excludes song metadata, credentials, raw URLs, headers and audio-route names.

Playback startup is measured from transport command to observed playhead progress, with 0.5-second sampling; it is not an acoustic measurement. Home latency ends when view-model data is available, before rendering. The counters are local and are not sent to a server.

## Regression coverage

- `PlayerRecoveryIntegrationTests`, `PlaybackExperienceTests` and existing engine/network suites: startup and final-retry grace periods, bounded recovery, Pause/Next intent, confirmed missing songs and stale callbacks.
- `PlaylistDetailOfflineTests` and `LibraryIndexTests`: confirmed deletion, transient errors, downloaded fallback and cache reconciliation.
- `HomeFeedContinuityTests`: independent sections, cached relaunch/offline access, server scoping and cancellation.
- `DownloadQueuePersistenceTests`: journal restore, completion replay, retries, storage failures, ownership and removal during preparation/commit.
- `DownloadTaskCoordinatorTests`, `OfflineDownloadRoundTripTests` and `OfflineLibraryRemovalCoordinatorTests`: shared cancellation, persisted ordering and safe removal of shared audio.
- `PlaylistEditCommitterTests` and `FavoritesFailureTests`: partial saves and persistent rollback after failed actions.
- `PlaybackDiagnosticsTests`: redaction and local continuity counters.

The complete Swift Testing run passed 843 tests in 137 suites on 5 September 2026. Subsequent changes passed 47 targeted tests (including two new favorites cases), followed by nine shared-download tests. The subsequent Next/reconnection correction passed 16 targeted tests, including a reproduced regression and verification that real retries remain visible.

Separate simulator UI runs passed onboarding with a local fixture, playlist playback/Pause/Next, concurrent download progress and completion, and welcome-screen readability at accessibility XXXL. Local playback was checked by observing the playhead advance while the fixture rejected all streams; Pause stopped that progression. A final queue scenario confirmed the upcoming song was visible with no album subtitle, Up Next heading or footer. Reproduction instructions are in [Scripts/Testing/README.md](../Scripts/Testing/README.md).

The signed Debug app, version 26.8.3 (25), was installed and launched on the paired iPhone. This verifies delivery and startup, separately from the simulator's functional coverage.

Real cellular handoffs, telephone interruptions, AirPods route changes and long-running background scheduling still require physical-device observation; passing simulated tests alone does not validate those conditions.
