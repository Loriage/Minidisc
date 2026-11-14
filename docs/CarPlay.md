# CarPlay

Minidisc exposes four audio tabs:

- **Home**: Smart Shuffle and recently added albums, including local files.
- **Library**: albums, artists, songs and favorite tracks.
- **Playlists**: server playlists, or playlists with playable downloads when offline.
- **Queue**: the current track and upcoming tracks from the shared player.

Selecting a song starts its displayed collection at the selected position. Album and
playlist queues retain all tracks even when the CarPlay list needs several pages.
The songs browser fetches additional server pages on demand. Now Playing uses
Apple's system template and Minidisc's existing metadata and remote commands, with
shuffle, repeat, album navigation and an Up Next button.

## Integration

`CarPlaySceneDelegate` obtains the same `MinidiscRuntime` as the iPhone and Siri.
It supports launch without an iPhone window and cancels UI work on disconnect.
Disconnecting CarPlay leaves the shared audio engine alive.

`CarPlayLibrary` merges local files with the existing library services. It reads
`OfflineBrowsingReader` directly when offline, so a phone view does not need to
refresh the offline snapshot first. Server/account revisions and online state are
checked after asynchronous reads and again inside the player's prepared-queue
transaction. Local availability is checked again when a song is selected.

`CarPlayController` owns templates, bounded artwork work and UI tasks. Queue actions
capture `QueueTrackSelection`, including queue revision and duplicate occurrences.
Player observations update the queue and playback buttons when the iPhone changes
playback. List paging respects `CPListTemplate.maximumItemCount`; deep navigation
returns to the root before exceeding the audio template stack limit.

The explicit scene manifest in `Info.plist` registers
`Minidisc.CarPlaySceneDelegate`. Automatic scene-manifest generation is disabled in
both app configurations because it otherwise replaces this dictionary. The unit
test `builtAppRegistersTheCarPlayScene` checks the **built app's** manifest.

New interface messages are in `CarPlay.xcstrings`, translated into all nine app
languages. Existing navigation labels use `Localizable.xcstrings`.

## Signing and testing

The app declares `com.apple.developer.carplay-audio`. Device and distribution
profiles must also authorize this entitlement. Request the audio capability from
[Apple](https://developer.apple.com/documentation/carplay/requesting-carplay-entitlements),
enable it for the app identifier once approved, and regenerate/download the profiles.

Run `CarPlayLibraryTests`, `MusicIntentTests` and `LocalMusicTests` with the
`MinidiscTests` scheme. They cover the built manifest, cold shared initialization,
local-only browsing, mixed sources, offline playlist order and duplicates, stale
connections, removed files, cancellation, pagination and full playback queues.

For visual verification, build and install the app in iOS Simulator with ad hoc
signing (`CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-`) so the CarPlay entitlement
is embedded. In Simulator choose **I/O > External Displays > CarPlay**, following
[Apple's simulator guide](https://developer.apple.com/documentation/carplay/using-the-carplay-simulator).

Verify browsing and playback, changes made from the phone, a cold launch from the
CarPlay launcher, disconnect/reconnect, server switching during a slow request,
offline mode and unavailable local files. On a real CarPlay system, also verify a
locked iPhone, Siri, navigation prompts and wired/wireless audio interruptions.

## Reference

The scene/template approach was informed by
[Cassette v1.13.2](https://github.com/CassetteLab/cassette/releases/tag/v1.13.2)
and its [CarPlay module](https://github.com/CassetteLab/cassette/tree/v1.13.2/Cassette/CarPlay).
Minidisc integrates this approach with its shared runtime, source isolation,
local music and offline catalogue.
