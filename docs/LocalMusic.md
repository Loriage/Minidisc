# Referenced music folders

Onboarding offers two explicit sources: Local Files and a music server. The local path explains folder access, opens the same folder manager used in Settings, and lets the listener enter their library without a server or add music later. Settings → Music Sources also lets a local-only listener connect a server later.

Home, Discover, Library and Search are the same tabs with or without a server. Home includes local albums in Recently Added; Library keeps its usual category rows and recent album grid. Albums, Artists and Songs combine server content (or downloaded server content offline) with indexed local files using the existing sorting, grid/list preferences, alphabetical navigation and row components. Local collection IDs are namespaced independently of server IDs, so matching names do not merge unrelated artists or albums.

Settings → Music Sources → Local Files provides folder management, including adding folders, song and availability counts, refresh progress and a restore-access action for inaccessible folders. Home and Library do not add a separate import action to their toolbars. The onboarding uses the same subdued button treatment for both source choices and a continuous background behind the folder page footer.

Search uses the shared scopes and relevance ranking for all sources; local tracks remain searchable even when unavailable. Discover's Smart Shuffle includes available local files and works without a configured server, including when the device is connected to the internet. Features requiring server data remain conditional. The player opens local album and artist pages using their local identity. Local and mixed Play/Shuffle queues preserve original DisplayableSong file references, filter unavailable files and preserve explicit shuffle state.

The local catalogue projection is rebuilt from the existing JSON index when tracks change or folders are removed. No SwiftData schema changes or migration are required. Files remain distinct from server downloads and retain their availability checks.

Audio stays at its original location. Minidisc stores directory bookmarks, a metadata index and extracted artwork in Application Support. Removing a folder only removes its index and artwork; it never deletes or moves the user's audio.

Directories, including subdirectories, are scanned on foreground entry, every 30 seconds while the app is active, and on pull to refresh. Unchanged files reuse indexed tags. This is foreground refresh, not a background filesystem watcher. Symbolic links are excluded, and overlapping directories are deduplicated during indexing.

Directory enumeration uses immediately available metadata coordination. Before reading tags or resolving playback, the library checks cloud download state and allocated file storage. Cloud placeholders remain listed but are not opened for metadata or playback. Minidisc never requests a cloud download; users manage download/restore in Files. Availability is checked again when playing or resuming.

The queue persists a folder ID and relative path, rather than an absolute URL. Playback retains a security-scoped access lease while its current or preloaded source is in use. Local tracks use the existing audio engine and system playback controls. Server playlist, favorite, sharing, lyrics and recommendation actions do not accept local references. Local tracks are excluded from server playback reporting and Wrapped statistics; an enabled ListenBrainz account can still scrobble their tags.
