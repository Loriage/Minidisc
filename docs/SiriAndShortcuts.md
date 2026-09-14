# Siri and Shortcuts

Open Minidisc and connect to a server once. For Siri's standard music commands,
open Settings → Application → Enable Siri and approve the system permission.
If access was denied, the same row opens the app's system settings.
After authorization, **Manage Siri Access** remains available and opens iOS
Settings, where access can be revoked. iOS does not expose an API for the app to
revoke the system permission itself; the row refreshes when the person returns.
In Shortcuts, add an action and choose
Minidisc. Available actions:

- Play Music: select a song, album, artist or playlist; optionally shuffle it.
- Play a Mood: play an existing generated Mood playlist.
- Smart Shuffle: start a personalized mix.
- Resume Playback, Pause Playback, Next Track and Previous Track.

These actions work in the background on iOS 26.1 and later. They can be combined
with other Shortcuts actions or used in personal automations. For example, a
shortcut can play the Night mood when a Focus is enabled.

Example Siri phrases in French:

- « Joue [titre, album, artiste ou playlist] dans Minidisc »
- « Lance l’ambiance Nuit dans Minidisc »
- « Lance Smart Shuffle dans Minidisc »
- « Reprends la lecture dans Minidisc »
- « Morceau suivant dans Minidisc »

The phrases and action labels are localized in all nine app languages. iOS 27
also exposes typed songs, albums, artists and playlists through Apple's audio
schemas, including shuffle, repeat, play-next and add-to-queue requests. Siri's
interpretation of spoken requests still depends on the device, language and
system configuration.

The app also handles `INPlayMediaIntent` and `INSearchForMediaIntent` in its existing application delegate,
with the Music media category and Siri entitlement. This supports the standard
SiriKit music route alongside App Shortcuts and iOS 27 audio schemas. Both routes
share the same runtime and playback service. SiriKit resolves media type and
artist constraints, asks for disambiguation when needed, and refuses a playlist
request when only an album of that name exists. For example, use “Play the album
Discovery by Daft Punk in Minidisc”, rather than calling that album a playlist.
Playlist requests search the playlist catalogue independently of song and album
results. Siri-supplied identifiers outside Minidisc's ID format fall back to the
provided title; valid Minidisc IDs still enforce their original account scope.
Search requests return matching media without starting playback.

SiriKit example phrases for both supported intents are shipped in
`AppIntentVocabulary.plist` in each of the nine language folders, with an English
`Base.lproj` fallback. These resources are separate from `AppShortcuts.xcstrings`;
keep them complete when adding an intent or localization to avoid App Store
Connect warning ITMS-90626. See Apple's [Intent Phrases reference](https://developer.apple.com/documentation/sirikit/intent-phrases).

Playback Diagnostics records the entry point (`sirikit-resolve`, `sirikit-play`,
`audio-search`, `audio-play`) and search result counts. It does not retain spoken
phrases, media titles or resource identifiers. These markers distinguish a
request the system never delivered from a catalog or playback failure.

Actions use the active Minidisc server. Saved music selections are tied to the
server endpoint and account; they never silently select a matching ID from
another account. Re-select music if the server address or resource IDs change.
Mood actions resolve the current playlist for the selected mood and do not
generate new playlists. Downloaded music uses the existing offline playback
path; voice recognition itself may still need a connection.

## Verification

`MusicIntentTests` covers account separation, batch entity resolution, bounded
local suggestions, ranking, and shared/retryable initialization. The player
recovery tests cover a Pause arriving while a shortcut prepares its queue and
applying the requested repeat mode.

`SiriMediaIntentTests` covers media-type filtering, artist disambiguation, generic
versus explicit requests, stable identifiers, and account changes between
resolution and playback. `testFixtureSiriSettings` checks the localized permission
entry point without granting permission on behalf of the person.
`testFixtureDiscoverWeeklyShortcut` creates a disposable playlist named Discover
Weekly, resolves it through the playlist entity query, and plays its first song
through the installed app's shortcut.

`testFixtureMusicShortcutsColdStart` uses AppIntentsTesting on the dedicated
**Minidisc UX Verification** simulator with the local fixture described in
[Scripts/Testing/README.md](../Scripts/Testing/README.md). It invokes the installed
app out of process, resolves music, starts playback, opens the app and exercises
Pause/Resume. It does not validate microphone recognition or Siri's spoken replies.

On a physical device, also test Siri with the app closed and the screen locked,
an album or playlist selected in Shortcuts, a downloaded selection offline, a
missing Mood, and an existing shortcut after switching servers.
