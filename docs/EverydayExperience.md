# Everyday listening experience

This pass covers search, song actions, playlists, Home and presentation. System integrations such as
widgets, Siri, Action button and CarPlay are outside this pass.

## Search

Search ranks exact titles before prefixes and mixed title/artist matches. Results include server
playlists, with All, Songs, Albums, Artists and Playlists filters. The top result appears once in All.
Previously displayed results stay visible during refresh; a request generation prevents an older
response from replacing a newer result or clearing its loading indicator. Search navigation owns no
SwiftData query; query-driven rows remain below it.

## Queue and song actions

Song rows share native Play Next, Add to Queue and Add to Playlist swipes. Scroll-based pages opt into
the iOS 27 swipe coordinator. The queue combines native dragging and swiping on iOS 27; iOS 26 keeps
its existing reorder handles.
The 44-point drag handle sits outside the row's context-menu region, so holding it starts a move.
List row background/separator traits apply after the iOS 27 reorderable wrapper to preserve the
player's cover background.

Queue row actions capture a session generation, structural revision, current position and destination
occurrence. Removal returns one undo token. Undo reinserts that occurrence without rebuilding the
queue or restarting playback. Next keeps the token valid if the queue is unchanged; a later structural
edit or extension-boundary change invalidates it. Duplicate song IDs remain distinct by position.

## Playlists

Search results, albums, playlists and the song library expose Select Songs. Filtering in the picker
preserves selection, and additions follow the original displayed order. The destination sheet searches
playlist names and places the five most recent successful destinations first, separately per server.
The player menu can save the full queue, including intentional repeated songs, as a playlist.
Confirmed catalogue mutations refresh the open Search and Home playlist collections, so a newly
created or renamed destination appears without restarting the app.

An append intent retains the original per-song counts and ordered additions. A retry reads fresh
playlist detail and appends only missing occurrences. A failed duplicate check never blindly writes.
Duplicate confirmation offers adding only new songs or preserving the full selection. A newly-created
playlist is kept after an append failure, so Retry finishes that destination. The earlier Add Music and
Create Playlist flows also retain their selections when the append fails.

## Home

Home exposes the current queue and progress, favorite songs/albums, recently played albums, frequent
albums outside those shelves, rediscovery, and recent additions matching favorite or frequently heard
artists. These are library additions, not claims about release dates. Playlists are labeled Your Playlists
because server modification time alone is not a personal recommendation.

Each source loads independently. Pull-to-refresh stages one layout update. Favorites and listening
habits are stored in optional cache fields so the previous Home cache still decodes offline. Discover
keeps exploration, fresh releases, moods, mixes, listening reports and radio instead of repeating Home's
history shelves.

Recent additions use the current server page online even when the local index is already complete;
otherwise Home could retain a previous scan's additions while background indexing finishes. Offline
or transient failures retain the local snapshot. Shared shelf headings wrap fully at accessibility
text sizes.
Album shelves widen their cards and allow complete metadata at those sizes. The fixed-height system
mini-player uses one metadata line with bounded symbol sizing; its accessibility label retains the
artist or playback status, and the full player remains available for the larger presentation.

## Validation

The focused suites cover ranking, late responses, queue occurrences and Undo, lost/partial append
responses, duplicate decisions, recent destination isolation, created destination reuse, personalized
selection and old/new offline cache formats. PlayerRecoveryIntegrationTests also exercise Undo after
Next through PlayerService, and retain the recovery/deleted-track cases.

UI verification uses only `Scripts/Testing/ux-fixture-server.py` and the disposable simulator named
Minidisc UX Verification. No real Navidrome library or downloads are used as fixture data.

Verified on 5 September 2026: the targeted unit suites and integration checks passed, as did the UI
flows for all search scopes, existing/new playlist additions, immediate search refresh, queue Undo,
native reordering, queue saving and personalized Home navigation. Final captures were inspected at
normal and Accessibility XXXL text sizes. The latest signed Debug build was installed and launched
on the physical iPhone; functional fixture playback checks ran on the isolated simulator. These
checks do not cover prolonged physical network handoffs or audio-route changes.
