import SwiftUI
import SwiftSonic
import SwiftData
import OSLog

// Keep SwiftData and observable reads in child views. Re-evaluating this view can
// recreate its navigation destinations and reset an active nested navigation flow.
// Navigation targets must remain plain values used with NavigationPath.
struct SearchHistoryNavTarget: Hashable {
    let itemId: String
    let itemType: String
    let displayName: String
    let coverArtId: String?
}

struct SearchView: View {
    @Binding var searchQuery: String
    @Binding var path: NavigationPath
    @Environment(\.appContainer) private var container
    @Environment(PlaylistAddition.self) private var playlistAddition
    @State private var viewModel: SearchViewModel?
    @State private var scope: LibrarySearchScope = .all
    @State private var loadedServerId: String?
    @Namespace private var albumZoomNamespace

    init(searchQuery: Binding<String>, path: Binding<NavigationPath>) {
        self._searchQuery = searchQuery
        self._path = path
    }

    private var serverId: String {
        container?.serverState.activeServer?.id.uuidString ?? ""
    }

    var body: some View {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespaces)
        Group {
            if trimmed.isEmpty {
                SearchHistoryListView(
                    serverId: serverId,
                    path: $path
                )
            } else {
                VStack(spacing: 0) {
                    SearchScopeBar(selection: $scope)
                    List {
                        if let vm = viewModel {
                            activeSearchContent(vm)
                        }
                    }
                    .listStyle(.plain)
                }
            }
        }
        .navigationDestination(for: ArtistID3.self) { artist in
            HistoryRecordingView {
                await container?.searchHistoryService.record(
                    itemId: artist.id, itemType: "artist",
                    displayName: artist.name, coverArtId: artist.coverArt,
                    serverId: serverId
                )
            } content: {
                ArtistDetailView(artist: artist)
            }
        }
        .navigationDestination(for: AlbumID3.self) { album in
            HistoryRecordingView {
                await container?.searchHistoryService.record(
                    itemId: album.id, itemType: "album",
                    displayName: album.name, coverArtId: album.coverArt,
                    serverId: serverId
                )
            } content: {
                AlbumDetailView(album: album)
            }
        }
        .navigationDestination(for: HomeDestination.self) { destination in
            switch destination {
            case .playlist(let playlist):
                HistoryRecordingView {
                    await container?.searchHistoryService.record(
                        itemId: playlist.id, itemType: "playlist", displayName: playlist.name,
                        coverArtId: playlist.coverArt, serverId: serverId
                    )
                } content: {
                    PlaylistDetailView(playlist: playlist)
                }
            case .album(let album):
                AlbumDetailView(
                    album: album,
                    zoomSourceId: album.id,
                    zoomNamespace: albumZoomNamespace,
                    coverArtId: album.coverArt
                )
            case .albumById(let id, let name, _, let coverArtId):
                AlbumDetailView(
                    albumId: id,
                    albumName: name,
                    zoomSourceId: id,
                    zoomNamespace: albumZoomNamespace,
                    coverArtId: coverArtId
                )
            case .artist(let artist):
                ArtistDetailView(artist: artist)
            case .artistById(let id, let name, let coverArtId):
                ArtistDetailView(artistId: id, artistName: name, coverArtId: coverArtId)
            case .artistBestOf(let id, let name, let coverArtId):
                ArtistBestOfView(artistId: id, artistName: name, coverArtId: coverArtId)
            default:
                EmptyView()
            }
        }
        .navigationDestination(for: SearchHistoryNavTarget.self) { entry in
            switch entry.itemType {
            case "artist":
                ArtistDetailView(artistId: entry.itemId, artistName: entry.displayName, coverArtId: entry.coverArtId)
            case "playlist":
                PlaylistDetailView(playlistId: entry.itemId, name: entry.displayName, coverArtId: entry.coverArtId)
            default:
                AlbumDetailView(albumId: entry.itemId, albumName: entry.displayName, coverArtId: entry.coverArtId)
            }
        }
        .onChange(of: serverId, initial: true) {
            guard let container, loadedServerId != serverId else { return }
            loadedServerId = serverId
            scope = .all
            viewModel = SearchViewModel(libraryService: container.libraryService,
                                        serverState: container.serverState,
                                        playlistBrowser: container.libraryService)
        }
        .task(id: loadedServerId) {
            await viewModel?.loadPlaylists()
        }
        .onReceive(NotificationCenter.default.publisher(for: .minidiscPlaylistDeleted)) { _ in
            Task { await viewModel?.loadPlaylists() }
        }
        .task(id: SearchRequest(serverId: loadedServerId, query: searchQuery)) {
            await viewModel?.search(query: searchQuery)
        }
        .minidiscContentWidth()
    }

    private struct SearchRequest: Equatable {
        let serverId: String?
        let query: String
    }

    // Search results live below this view's navigation owner. In particular, favorites and
    // downloaded-track queries must never invalidate the navigation destinations themselves.
    @ViewBuilder
    private func activeSearchContent(_ vm: SearchViewModel) -> some View {
        let matches = vm.matches
        if !matches.isEmpty {
            SearchResultsContent(matches: matches, scope: $scope,
                                 onAddToPlaylist: playlistAddition.present)
        }
        if vm.isSearching || (scope == .playlists && vm.isLoadingPlaylists) {
            let title: LocalizedStringResource = matches.isEmpty ? "Searching…" : "Updating results…"
            HStack(spacing: MinidiscSpacing.s) {
                ProgressView()
                Text(title)
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .listRowSeparator(.hidden)
        }
        if (scope == .all || scope == .playlists), let error = vm.playlistError {
            SearchRetryRow(message: error.displayMessage) { Task { await vm.loadPlaylists() } }
        } else if let error = vm.searchError {
            SearchRetryRow(message: error.displayMessage) { Task { await vm.search(query: searchQuery) } }
        }
        if (vm.isOffline || vm.searchError != nil), scope != .playlists {
            LocalSearchResultsSection(
                query: searchQuery.trimmingCharacters(in: .whitespaces),
                scope: scope,
                onAddToPlaylist: playlistAddition.present
            )
        } else if matches.filter({ scope == .all || $0.scope == scope }).isEmpty,
                  !vm.isSearching, !vm.isLoadingPlaylists,
                  vm.resultsQuery == searchQuery.trimmingCharacters(in: .whitespaces),
                  vm.searchError == nil, (scope != .playlists || vm.playlistError == nil) {
            EmptyStateView(
                systemImage: "magnifyingglass",
                title: "No results",
                subtitle: "Try another category or search term."
            )
            .listRowSeparator(.hidden)
        }
    }

    // MARK: - Local (downloads) results
    //
    // Isolated in a child view for the same reason as SearchSongResultsSection: it owns a @Query,
    // which must never be read from SearchView's body (see the warning at the top of this file).

    private struct LocalSearchResultsSection: View {
        let query: String
        let scope: LibrarySearchScope
        let onAddToPlaylist: (DisplayableSong) -> Void

        @Environment(\.appContainer) private var container
        /// Unfiltered — the active server isn't known when the Query is built, so it's applied at read time.
        @Query private var allTracks: [DownloadedTrack]

        private var tracks: [DownloadedTrack] {
            guard let serverId = container?.serverState.activeServer?.id else { return [] }
            return allTracks.filter { $0.serverId == serverId }
        }

        /// Diacritic- and case-insensitive, so "aime" finds "Aimé" and "orelsan" finds "OrelSan".
        private func matches(_ haystack: String?) -> Bool {
            guard let haystack else { return false }
            return haystack.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }

        private var matchingTracks: [DownloadedTrack] {
            tracks.filter { matches($0.title) || matches($0.artist) || matches($0.album) }
        }

        /// Artists are only offered when their tracks carry an artistId — without one there is nothing
        /// stable to navigate to, and grouping by name alone would merge namesakes.
        private var artists: [ArtistID3] {
            let named = tracks.filter { matches($0.artist) && $0.artistId != nil }
            return Dictionary(grouping: named, by: { $0.artistId! })
                .map { artistId, tracks in
                    ArtistID3(
                        id: artistId,
                        name: tracks[0].artist ?? artistId,
                        albumCount: Set(tracks.compactMap(\.albumId)).count,
                        coverArt: tracks.compactMap(\.coverArtId).first
                    )
                }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }

        private var albums: [AlbumID3] {
            let named = tracks.filter { (matches($0.album) || matches($0.artist)) && $0.albumId != nil }
            return Dictionary(grouping: named, by: { $0.albumId! })
                .map { albumId, tracks in
                    // No year: downloads never persist one.
                    AlbumID3(
                        id: albumId,
                        name: tracks[0].album ?? albumId,
                        songCount: tracks.count,
                        duration: tracks.reduce(0) { $0 + ($1.durationSeconds ?? 0) },
                        artist: tracks[0].artist,
                        artistId: tracks.compactMap(\.artistId).first,
                        coverArt: tracks.compactMap(\.coverArtId).first
                    )
                }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }

        var body: some View {
            let songs = matchingTracks
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
                .map { DisplayableSong(from: $0) }
            let hasVisibleResults = ((scope == .all || scope == .songs) && !songs.isEmpty)
                || ((scope == .all || scope == .artists) && !artists.isEmpty)
                || ((scope == .all || scope == .albums) && !albums.isEmpty)
            if !hasVisibleResults {
                EmptyStateView(
                    systemImage: "wifi.slash",
                    title: "No Downloaded Matches",
                    subtitle: "Only downloaded music can be searched while offline."
                )
                .listRowSeparator(.hidden)
            } else {
                if !artists.isEmpty, scope == .all || scope == .artists {
                    Section("Artists") {
                        ForEach(artists) { artist in
                            NavigationLink(value: artist) { ArtistRow(artist: artist) }
                        }
                    }
                }
                if !albums.isEmpty, scope == .all || scope == .albums {
                    Section("Albums") {
                        ForEach(albums) { album in
                            NavigationLink(value: album) {
                                AlbumRow(
                                    albumId: album.id,
                                    name: album.name,
                                    artist: album.artist,
                                    year: nil,
                                    coverArtId: album.coverArt
                                )
                            }
                        }
                    }
                }
                if scope == .all || scope == .songs {
                    SearchSongResultsSection(songs: songs, onAddToPlaylist: onAddToPlaylist)
                }
            }
        }
    }

    // MARK: - Song results section (isolated to prevent @Query re-renders in SearchView body)

    private struct SearchSongResultsSection: View {
        let songs: [DisplayableSong]
        let onAddToPlaylist: (DisplayableSong) -> Void

        @Environment(\.appContainer) private var container
        @Query private var allFavorites: [FavoriteRecord]

        private var favoriteSongIds: Set<String> {
            Set(allFavorites.map(\.id))
        }

        var body: some View {
            if !songs.isEmpty {
                Section("Songs") {
                    ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                        SongRow(
                            song: song,
                            index: index + 1,
                            showCoverArt: true,
                            isFavorite: favoriteSongIds.contains("song:\(song.id)"),
                            onAddToPlaylist: { s in onAddToPlaylist(s) }
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            Task {
                                do {
                                    try await container?.playerService.play(tracks: songs, startIndex: index)
                                } catch {
                                    Logger.player.error("[PLAYBACK] play failed: \(error, privacy: .public)")
                if !UserFacingError.isCancellation(error) {
                    container?.toastService.showError(UserFacingError.from(error).displayMessage)
                }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Search history list

    private struct SearchHistoryListView: View {
        let serverId: String
        @Binding var path: NavigationPath

        @Environment(\.appContainer) private var container
        @Query private var historyEntries: [SearchHistoryEntry]
        @State private var showClearConfirm = false

        init(serverId: String, path: Binding<NavigationPath>) {
            self.serverId = serverId
            self._path = path
            var descriptor = FetchDescriptor<SearchHistoryEntry>(
                sortBy: [SortDescriptor(\.visitedAt, order: .reverse)]
            )
            descriptor.fetchLimit = 50
            _historyEntries = Query(descriptor)
        }

        private var serverHistory: [SearchHistoryEntry] {
            historyEntries.filter { $0.serverId == serverId }
        }

        var body: some View {
            let history = serverHistory
            let rowsData = history.map { SearchHistoryRowData(entry: $0) }
            if history.isEmpty {
                EmptyStateView(
                    systemImage: "magnifyingglass",
                    title: "Search your library",
                    subtitle: "Find songs, albums, artists, and playlists from your server."
                )
            } else {
                List {
                    Section {
                        LazyVStack(spacing: 0) {
                            ForEach(rowsData) { rowData in
                                Button {
                                    let target = SearchHistoryNavTarget(
                                        itemId: rowData.itemId,
                                        itemType: rowData.itemType,
                                        displayName: rowData.displayName,
                                        coverArtId: rowData.coverArtId
                                    )
                                    Task {
                                        await container?.searchHistoryService.record(
                                            itemId: rowData.itemId, itemType: rowData.itemType,
                                            displayName: rowData.displayName, coverArtId: rowData.coverArtId,
                                            serverId: serverId
                                        )
                                    }
                                    path.append(target)
                                } label: {
                                    SearchHistoryEntryRow(data: rowData)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    } header: {
                        HStack {
                            Text("Recent")
                                .font(.minidiscSectionTitle)
                                .foregroundStyle(.primary)
                            Spacer()
                            Button("Clear") {
                                showClearConfirm = true
                            }
                            .font(.minidiscBody)
                            .foregroundStyle(Color.minidiscAccent)
                        }
                        .textCase(nil)
                    }
                }
                .listStyle(.plain)
                // Clearing search history is destructive with no undo, so gate it behind a confirmation.
                // A centered .alert (popin) is used here — intentionally diverging from the playlist
                // delete's bottom action-sheet. The clear runs ONLY on confirm; Cancel leaves the history
                // intact. .alert is a centered modal.
                .alert("Clear search history?", isPresented: $showClearConfirm) {
                    Button("Clear", role: .destructive) {
                        Task { await container?.searchHistoryService.clear(serverId: serverId) }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This will remove all your recent searches. This action cannot be undone.")
                }
            }
        }
    }

    // MARK: - History recording wrapper

    private struct HistoryRecordingView<Content: View>: View {
        let action: () async -> Void
        @ViewBuilder let content: () -> Content
        var body: some View {
            content().task { await action() }
        }
    }
}
