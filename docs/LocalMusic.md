# Referenced music folders

Settings → Local Files → Add Folder selects one or more directories in Files. Library shows Local Files only while at least one folder is configured. The local landing page previews the most recently added albums, artists and songs in three shelves. Each header opens a searchable, sortable browse page with an alphabetical index, grid/list layout for collections and standard song rows with queue actions. Addition dates persist across refreshes and metadata changes; older indexes fall back to their saved file modification dates. Album pages share the main library’s artwork and color treatment. A local-only entry is also available from onboarding, without configuring a server.

Audio stays at its original location. Minidisc stores directory bookmarks, a metadata index and extracted artwork in Application Support. Removing a folder only removes its index and artwork; it never deletes or moves the user's audio.

Directories, including subdirectories, are scanned on foreground entry, every 30 seconds while the app is active, and on pull to refresh. Unchanged files reuse indexed tags. This is foreground refresh, not a background filesystem watcher. Symbolic links are excluded, and overlapping directories are deduplicated during indexing.

Directory enumeration uses immediately available metadata coordination. Before reading tags or resolving playback, the library checks cloud download state and allocated file storage. Cloud placeholders remain listed but are not opened for metadata or playback. Minidisc never requests a cloud download; users manage download/restore in Files. Availability is checked again when playing or resuming.

The queue persists a folder ID and relative path, rather than an absolute URL. Playback retains a security-scoped access lease while its current or preloaded source is in use. Local tracks use the existing audio engine and system playback controls. Server playlist, favorite, sharing, lyrics and recommendation actions do not accept local references. Local tracks are excluded from server playback reporting and Wrapped statistics; an enabled ListenBrainz account can still scrobble their tags.

## Device verification

- Add an on-device folder containing supported audio and a subfolder. Play, pause, seek, advance, and relaunch the app.
- Add an iCloud folder containing both downloaded files and placeholders. Confirm placeholders show an explanation and tapping one does not download it. Download it manually in Files, then refresh.
- Add/remove a file in Files, return to Minidisc, and verify the index updates.
- Revoke folder access or move/delete a referenced file. Verify the unavailable message and ability to add the folder again.
- Remove a folder from Minidisc and confirm the originals remain in Files.

The simulator suite verifies indexing, persisted bookmarks, overlap deduplication, missing files/folders, cloud residency policy, legacy queue decoding and local playback without a server. Real iCloud eviction and permission revocation require a signed-in physical device.
