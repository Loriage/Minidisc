# Everyday listening experience

This pass covers search, song actions, playlists, Home and presentation. System integrations such as
widgets, Siri, Action button and CarPlay are outside this pass.

## Search

Search ranks exact titles before prefixes and mixed title/artist matches. Results include server
playlists, with All, Songs, Albums, Artists and Playlists filters. The top result appears once in All.
Previously displayed results stay visible during refresh; a request generation prevents an older
response from replacing a newer result or clearing its loading indicator. Search navigation owns no
SwiftData query; query-driven rows remain below it.
The navigation search field stays visible on entry without activating the keyboard. Category chips
use their full-width clipped carousel; Select belongs to the appropriate result heading, so it cannot
cover a chip while scrolling horizontally. At accessibility text sizes, Select moves below the heading
and keeps its complete label on one line.

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

Home leads with large playlist covers ordered by server modification time, with that update shown
under each cover. This keeps regularly regenerated Navidrome playlists prominent. The mini-player
remains the single current-playback surface; the duplicate Now Playing/Continue Listening card was
removed after device feedback. Favorite songs/albums, recently played albums, frequent albums outside
those shelves, rediscovery, and recent additions matching familiar artists follow the playlists.
These additions are library additions, not claims about release dates.

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

## Discover and library navigation

Stations for You uses actual favorite and recently/frequently heard library artist IDs. A favorite song
can start immediately while the existing artist Instant Mix fills the queue behind it. Distinct artists
with the same name remain separate. Failed history and favorites requests do not hide each other's
stations, and a failed refresh retains the previous collection. Smart Shuffle has an illustrated card
with library artwork and preparation feedback. Stations show the artist's name followed by
& Similar artists as the title, and Radio Station as the subtitle. The whole card starts playback and its
subtitle shows preparation feedback. Captions wrap fully at accessibility text sizes. Fresh Releases is
absent when its result collection is empty, including for a connected ListenBrainz account.

Playlists, Albums, Artists, Songs, Favorites and Downloads use inline titles. Favorites has no redundant
Songs heading. Album and artist indexes work in lists, grids and downloaded fallbacks; selecting a
letter switches to name order when needed. The index uses canonical sort names and folds accented
initials, with non-Latin names and numbers reachable under #. Favorites and Downloads index their
displayed categories in order using type-prefixed anchors, including standalone songs and playlists.
The List data sources use those same prefixed identities, so a letter can resolve an offscreen row
before that row's view has been created.

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

The subsequent visual refinements retain the previous playback engine. All 31 targeted tests passed:
station identity/starter selection, partial source failures, alphabet bucket resolution, Fresh Releases
responses, search ranking and debounce/cancellation. Eleven UI scenarios passed across focused runs,
covering playlist priority and update dates, directly accessible Search and selection, inline titles,
album/artist list and grid indexes, all four Downloads letter buckets, mixed Favorites categories,
artist-seeded playback and Smart Shuffle queue progression. Final French captures were inspected at
normal and Accessibility XXXL sizes. The signed Debug build containing these refinements was also
installed and launched on the physical iPhone on 5 September 2026.

The simplified station presentation was then checked in two focused UI tests at normal and
Accessibility XXXL sizes: artist-only titles, separate Similar Artists subtitles, and no play overlay.
Tapping the card still starts the exact artist seed, with confirmed audio progress. The corresponding
signed Debug build was installed and launched on the same iPhone.

The empty Fresh Releases UI check uses an account without ListenBrainz configured; the connected-empty
case is covered by model tests and the view condition, not a connected-account UI fixture.
