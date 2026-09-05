import SwiftUI
import SwiftSonic

/// Listening continuity and familiar music, with server-scoped cached shelves.
struct HomeView: View {
    var onOpenPlayer: () -> Void = {}
    @Environment(\.appContainer) private var container
    @Environment(ArtworkImageCache.self) private var artworkImageCache
    @State private var viewModel: HomeFeedViewModel?
    @State private var showSettings = false
    @State private var loadedServerID: UUID?

    private struct LoadIdentity: Hashable { let serverID: UUID?; let online: Bool }
    @Namespace private var homeZoomNamespace

    private var isOnline: Bool { container?.serverState.isOnline == true }

    var body: some View {
        Group {
            if let vm = viewModel {
                content(vm)
            } else {
                LoadingStateView()
            }
        }
        .navigationTitle("Home")
        .toolbarTitleDisplayMode(.inlineLarge)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Settings", systemImage: "gearshape.fill") { showSettings = true }
                    .tint(.primary)
            }
        }
        .sheet(isPresented: $showSettings) { SettingsSheet() }
        .navigationDestination(for: HomeDestination.self) { destination in
            resolve(destination)
        }
        .task(id: LoadIdentity(serverID: container?.serverState.activeServer?.id, online: isOnline)) {
            guard let c = container, let serverID = c.serverState.activeServer?.id else { return }
            if viewModel == nil || loadedServerID != serverID {
                loadedServerID = serverID
                viewModel = HomeFeedViewModel(libraryService: c.libraryService, cache: HomeFeedCache.shared, serverID: serverID,
                                              diagnostics: c.playbackDiagnostics)
            }
            await viewModel?.load(isOnline: isOnline)
        }
        .onReceive(NotificationCenter.default.publisher(for: .minidiscPlaylistsChanged)) { _ in
            Task { await viewModel?.load(isOnline: isOnline, preserveLayout: true) }
        }
    }

    // MARK: - Feed

    @ViewBuilder
    private func content(_ vm: HomeFeedViewModel) -> some View {
        let hasResume = container?.playerState.currentTrack != nil && container?.playerState.isLiveStream == false
        if !vm.isLoading, vm.isEmpty, !isOnline, !hasResume {
            OfflineHomeInfo()
        } else if let error = vm.error, vm.isEmpty, !vm.isLoading, !hasResume {
            EmptyStateView(
                systemImage: "exclamationmark.triangle",
                title: "Unable to Load",
                subtitle: LocalizedStringKey(error.displayMessage),
                action: .init(label: "Retry") { Task { await vm.load() } }
            )
        } else if vm.isEmpty && !vm.isLoading && !hasResume {
            EmptyStateView(
                systemImage: "music.note.list",
                title: "No music yet",
                subtitle: "Add some music to your server to get started"
            )
        } else {
            ScrollView {
                // A plain VStack (not LazyVStack): the feed is a handful of shelves, so a deterministic
                // content height is cheap — and a LazyVStack's estimated height confuses the
                // pull-to-refresh inset math, stranding the ScrollView with a blank gap at the top.
                VStack(alignment: .leading, spacing: MinidiscSpacing.xxl) {
                    if !isOnline {
                        OfflineHomeInfo()
                    } else if vm.hasPartialFailure {
                        HStack(alignment: .center) {
                            Text("Some sections could not be refreshed. Your saved library is still available.")
                                .font(.subheadline)
                            Spacer()
                            Button("Retry") { Task { await vm.load(isOnline: isOnline, preserveLayout: true) } }
                                .frame(minHeight: 44)
                        }
                        .padding(.horizontal, MinidiscSpacing.l)
                    }
                    HomeResumeCard(onOpenPlayer: onOpenPlayer)
                    HomeFavoriteSongsSection(songs: vm.favorites.songs)
                    HomeAlbumSection(title: "Your Favorite Albums", albums: vm.favorites.albums, identifier: "home.favoriteAlbums")
                    if vm.topPicks.isEmpty, vm.pendingSections.contains(.playlists) {
                        HomeShelfPlaceholder(title: "Your Playlists", side: 250)
                    }
                    if !vm.topPicks.isEmpty {
                        MinidiscShelf {
                            MinidiscCarouselHeaderLink(
                                "Your Playlists",
                                itemCount: vm.topPicks.count
                            ) {
                                PlaylistCarouselCollectionView(
                                    "Your Playlists",
                                    playlists: vm.topPicks
                                )
                            }
                        } content: {
                            ForEach(Array(vm.topPicks.prefix(MinidiscCarouselMetrics.previewLimit))) { playlist in
                                TopPickCard(playlist: playlist, namespace: homeZoomNamespace)
                            }
                        }
                    }
                    if vm.recentlyPlayed.isEmpty, vm.pendingSections.contains(.history) {
                        HomeShelfPlaceholder(title: "Recently Played", side: 160)
                    }
                    HomeAlbumSection(title: "Recently Played", albums: vm.recentlyPlayed, identifier: "home.recentlyPlayed")
                    HomeAlbumSection(title: "In Heavy Rotation", albums: vm.heavyRotation, identifier: "home.heavyRotation")
                    HomeAlbumSection(title: "Rediscover", albums: vm.rediscovery, identifier: "home.rediscover")
                    HomeAlbumSection(title: "Recently Added from Your Artists", albums: vm.relevantAdditions, identifier: "home.relevantAdditions")
                    if vm.recentlyAdded.isEmpty, vm.pendingSections.contains(.recent) {
                        HomeShelfPlaceholder(title: "Recently Added", side: 160)
                    }
                    HomeAlbumSection(title: "Recently Added", albums: vm.otherAdditions, identifier: "home.recentlyAdded")
                    ForEach(vm.genreShelves) { shelf in
                        MinidiscShelf {
                            MinidiscCarouselHeaderLink(
                                verbatim: shelf.name,
                                itemCount: shelf.albums.count
                            ) {
                                AlbumCarouselCollectionView(
                                    verbatim: shelf.name,
                                    albums: shelf.albums
                                )
                            }
                        } content: {
                            ForEach(Array(shelf.albums.prefix(MinidiscCarouselMetrics.previewLimit))) { album in
                                AlbumShelfCard(album: album)
                            }
                        }
                    }
                }
                .padding(.top, MinidiscSpacing.m)
                .padding(.bottom, MinidiscSpacing.xl)
            }
            .minidiscSongSwipeContainer()
            .refreshable { await vm.load(isOnline: isOnline, preserveLayout: true) }
        }
    }

    // MARK: - Destination resolver

    @ViewBuilder
    private func resolve(_ destination: HomeDestination) -> some View {
        switch destination {
        case .libraryAlbums:
            AlbumsListView()
        case .libraryArtists:
            ArtistListView()
        case .librarySongs:
            SongsListView()
        case .libraryPlaylists:
            PlaylistListView()
        case .libraryFavorites:
            FavoritesView()
        case .libraryDownloads:
            DownloadedView()
        case .album(let album):
            AlbumDetailView(album: album)
        case .artist(let artist):
            ArtistDetailView(artist: artist)
        case .playlist(let playlist):
            PlaylistDetailView(
                playlist: playlist,
                coverArtId: playlist.coverArt ?? playlist.id,
                initialCoverImage: artworkImageCache.cachedImage(for: playlist.coverArt ?? playlist.id),
                zoomSourceId: playlist.id,
                zoomNamespace: homeZoomNamespace
            )
        case .downloadedAlbum(let display):
            AlbumDetailView(albumId: display.albumId, albumName: display.name, coverArtId: display.coverArtId, mode: .downloadedOnly)
        case .albumById(let id, let name, _, let coverArtId):
            AlbumDetailView(albumId: id, albumName: name, coverArtId: coverArtId)
        case .playlistById(let id, let name, let coverArtId):
            PlaylistDetailView(
                playlistId: id,
                name: name,
                coverArtId: coverArtId,
                initialCoverImage: artworkImageCache.cachedImage(for: coverArtId ?? id)
            )
        case .artistById(let id, let name, let coverArtId):
            ArtistDetailView(artist: ArtistID3(id: id, name: name, coverArt: coverArtId))
        case .artistBestOf(let id, let name, let coverArtId):
            ArtistBestOfView(artistId: id, artistName: name, coverArtId: coverArtId)
        case .recentlyAdded(let coverArtId):
            RecentlyAddedView(coverArtId: coverArtId)
        case .offlineArtist(let artist):
            OfflineArtistAlbumsView(artist: artist)
        case .offlineAlbum(let album):
            AlbumDetailView(albumId: album.albumId, albumName: album.albumName, coverArtId: album.coverArtId)
        }
    }
}

// MARK: - Top pick card (large, Apple-Music style)

private struct TopPickCard: View {
    let playlist: Playlist
    let namespace: Namespace.ID

    private let side: CGFloat = 250

    var body: some View {
        NavigationLink(value: HomeDestination.playlist(playlist)) {
            VStack(alignment: .leading, spacing: MinidiscSpacing.s) {
                PlaylistCoverThumbnail(
                    playlistId: playlist.id,
                    serverId: nil,
                    coverArtId: playlist.coverArt ?? playlist.id,
                    title: playlist.name,
                    size: side
                )
                .minidiscMatchedTransitionSource(id: playlist.id, in: namespace)
                CoverCardMetadata(
                    title: playlist.name,
                    subtitle: String(localized: "\(playlist.songCount) tracks")
                )
            }
            .frame(width: side, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}

private struct OfflineHomeInfo: View {
    var body: some View {
        VStack(alignment: .leading, spacing: MinidiscSpacing.s) {
            Label("You're Offline", systemImage: "wifi.slash").font(.headline)
            Text("Your saved library stays here. Downloaded music is ready to play.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            NavigationLink(value: HomeDestination.libraryDownloads) {
                Label("Downloaded Music", systemImage: "arrow.down.circle")
                    .frame(minHeight: 44)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, MinidiscSpacing.l)
    }
}

private struct HomeShelfPlaceholder: View {
    let title: LocalizedStringResource
    let side: CGFloat
    var body: some View {
        MinidiscShelf {
            MinidiscCarouselHeader(title, showsChevron: false)
        } content: {
            ForEach(0..<3) { _ in
                VStack(alignment: .leading, spacing: MinidiscSpacing.s) {
                    RoundedRectangle(cornerRadius: MinidiscCornerRadius.standard)
                        .fill(.quaternary).frame(width: side, height: side)
                    Text("Loading…").font(.subheadline)
                    Text("Loading…").font(.caption)
                }
                .redacted(reason: .placeholder)
                .frame(width: side, alignment: .leading)
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue("Loading")
    }
}
