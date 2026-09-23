import SwiftUI
import SwiftData
import SwiftSonic
import OSLog

struct PlaylistListView: View {
    var zoomNamespace: Namespace.ID? = nil
    @Environment(\.appContainer) private var container
    @State private var viewModel: PlaylistListViewModel?
    @State private var showCreateSheet = false

    var body: some View {
        Group {
            if let vm = viewModel {
                content(vm)
            } else {
                LoadingStateView()
            }
        }
        .minidiscContentWidth()
        .navigationTitle("Playlists")
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showCreateSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .tint(.primary)
                .disabled(container?.serverState.isOnline != true)
            }
        }
        .sheet(isPresented: $showCreateSheet) {
            CreatePlaylistSheet { _ in
                Task { await viewModel?.load() }
            }
        }
        .task(id: container?.serverState.isOnline) {
            guard let svc = container?.libraryService else { return }
            if viewModel == nil { viewModel = PlaylistListViewModel(libraryService: svc) }
            guard container?.serverState.isOnline == true else { return }
            await viewModel?.load()
            await viewModel?.loadBestOf()
            await viewModel?.loadRecentlyAdded()
        }
        // Reload after confirmed deletion without refetching on every navigation.
        .onReceive(NotificationCenter.default.publisher(for: .minidiscPlaylistDeleted)) { _ in
            Task { await viewModel?.load() }
        }
    }

    private func displayedPlaylists(_ vm: PlaylistListViewModel) -> [Playlist] {
        container?.serverState.isOnline == false ? container?.offlineLibrary.snapshot.playlists ?? [] : vm.playlists
    }

    @ViewBuilder
    private func content(_ vm: PlaylistListViewModel) -> some View {
        if container?.serverState.isOnline != false && vm.isLoading && displayedPlaylists(vm).isEmpty {
            LoadingStateView()
        } else if container?.serverState.isOnline == false && displayedPlaylists(vm).isEmpty {
            OfflineBrowsingEmptyView()
        } else if let error = vm.error, displayedPlaylists(vm).isEmpty {
            EmptyStateView(
                systemImage: "exclamationmark.triangle",
                title: "Unable to Load Playlists",
                subtitle: LocalizedStringKey(error.displayMessage),
                action: .init(label: "Retry") { Task { await vm.load() } }
            )
        } else if displayedPlaylists(vm).isEmpty && !hasDerivedPlaylists(vm) {
            EmptyStateView(
                systemImage: "list.bullet",
                title: "No Playlists",
                subtitle: "Create playlists on your server to see them here."
            )
        } else {
            List {
                if hasDerivedPlaylists(vm) {
                    Section("Made For You") {
                        if let newest = vm.newestAlbum {
                            NavigationLink(value: HomeDestination.recentlyAdded(
                                coverArtId: newest.coverArt ?? newest.id
                            )) {
                                RecentlyAddedPlaylistRow(coverArtId: newest.coverArt ?? newest.id)
                            }
                        }
                        ForEach(vm.bestOfPlaylists) { bestOf in
                            NavigationLink(value: HomeDestination.artistBestOf(
                                artistId: bestOf.artistId,
                                artistName: bestOf.artistName,
                                coverArtId: bestOf.coverArtId
                            )) {
                                BestOfPlaylistRow(bestOf: bestOf)
                            }
                        }
                    }
                }
                // Label the server playlists only when there's a derived section above to tell them apart
                // from — on its own the header would just repeat the screen title.
                if !hasDerivedPlaylists(vm) {
                    serverPlaylistRows(vm)
                } else if !displayedPlaylists(vm).isEmpty {
                    Section("Playlists") { serverPlaylistRows(vm) }
                }
            }
            .listStyle(.plain)
            .refreshable {
                await vm.load()
                await vm.loadBestOf()
                await vm.loadRecentlyAdded()
            }
        }
    }

    private func hasDerivedPlaylists(_ vm: PlaylistListViewModel) -> Bool {
        container?.serverState.isOnline != false && (vm.newestAlbum != nil || !vm.bestOfPlaylists.isEmpty)
    }

    @ViewBuilder
    private func serverPlaylistRows(_ vm: PlaylistListViewModel) -> some View {
        ForEach(displayedPlaylists(vm)) { playlist in
            NavigationLink(value: HomeDestination.playlist(playlist)) {
                OnlinePlaylistRow(
                    playlist: playlist,
                    namespace: zoomNamespace,
                    onActionCompleted: { Task { await vm.load() } }
                )
            }
        }
    }
}

// MARK: - Online playlist row

private struct OnlinePlaylistRow: View {
    let playlist: Playlist
    var namespace: Namespace.ID? = nil
    var onActionCompleted: (() -> Void)? = nil

    @Environment(\.appContainer) private var container
    @Environment(ArtworkImageCache.self) private var artworkImageCache
    @State private var coverImage: PlatformImage?
    @State private var showDeleteConfirm = false
    @Query private var downloadedMatches: [DownloadedPlaylist]

    init(playlist: Playlist, namespace: Namespace.ID? = nil, onActionCompleted: (() -> Void)? = nil) {
        self.playlist = playlist
        self.namespace = namespace
        self.onActionCompleted = onActionCompleted
        let pid = playlist.id
        _downloadedMatches = Query(filter: #Predicate<DownloadedPlaylist> { $0.playlistId == pid })
    }

    var body: some View {
        HStack(spacing: MinidiscSpacing.m) {
            PlaylistCoverThumbnail(playlistId: playlist.id, serverId: nil, coverArtId: playlist.coverArt ?? playlist.id, title: playlist.name, size: 56)
                .minidiscMatchedTransitionSource(id: playlist.id, in: namespace)
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .font(.minidiscCellTitle)
                    .lineLimit(1)
                Text("\(playlist.songCount) tracks")
                    .font(.minidiscCaption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, MinidiscSpacing.xs)
        .task(id: playlist.id) {
            coverImage = await artworkImageCache.load(coverArtId: playlist.coverArt ?? playlist.id)
        }
        .collectionContextMenu(
            itemType: .playlist,
            itemId: playlist.id,
            displayName: playlist.name,
            displaySubtitle: "Playlist",
            coverArtId: playlist.coverArt,
            coverImage: coverImage,
            onDelete: { showDeleteConfirm = true }
        )
        .deletePlaylistConfirmation(
            playlistName: playlist.name,
            isPresented: $showDeleteConfirm,
            hasDownloads: !downloadedMatches.isEmpty
        ) { purgeDownloads in
            Task {
                guard let container else { return }
                do {
                    // The service deletes server-side first and rolls its own cache back on failure, so it is
                    // safe to refresh the (server-fresh) list only AFTER a confirmed success.
                    try await container.playlistService.deletePlaylist(id: playlist.id, purgeDownloads: purgeDownloads)
                    onActionCompleted?()
                    container.toastService.showConfirmation("Playlist deleted")
                } catch {
                    Logger.playlist.error("[PLAYLIST] delete failed id=\(playlist.id, privacy: .public): \(error, privacy: .public)")
                    container.toastService.showError("Couldn't delete playlist. Please try again.")
                }
            }
        }
    }
}

// MARK: - Derived "Recently Added" row

/// Derived playlist: there is no server entity for context-menu mutations.
private struct RecentlyAddedPlaylistRow: View {
    let coverArtId: String

    var body: some View {
        HStack(spacing: MinidiscSpacing.m) {
            CoverArtView(id: coverArtId, size: 112)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: MinidiscCornerRadius.standard, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("Recently Added")
                    .font(.minidiscCellTitle)
                    .lineLimit(1)
                // No track count: knowing it would mean fetching every album's tracks just to draw a row.
                Text("The newest tracks in your library")
                    .font(.minidiscCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, MinidiscSpacing.xs)
    }
}

// MARK: - Derived "best of" row

/// Derived playlist: there is no server entity for context-menu mutations.
private struct BestOfPlaylistRow: View {
    let bestOf: ArtistBestOf

    var body: some View {
        HStack(spacing: MinidiscSpacing.m) {
            CoverArtView(id: bestOf.coverArtId ?? bestOf.artistId, size: 112)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: MinidiscCornerRadius.standard, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("The best of \(bestOf.artistName)")
                    .font(.minidiscCellTitle)
                    .lineLimit(1)
                Text("\(bestOf.songs.count) tracks")
                    .font(.minidiscCaption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, MinidiscSpacing.xs)
    }
}

// MARK: - Offline Playlists
