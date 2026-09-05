import SwiftUI
import SwiftSonic

/// Personalized Home feed: Top Picks (freshest playlists), Recently Played,
/// then one shelf per top library genre. The full library lives in the Library tab.
struct HomeView: View {
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
        .onReceive(NotificationCenter.default.publisher(for: .minidiscPlaylistDeleted)) { _ in
            Task { await viewModel?.load(isOnline: isOnline, preserveLayout: true) }
        }
    }

    // MARK: - Feed

    @ViewBuilder
    private func content(_ vm: HomeFeedViewModel) -> some View {
        if !vm.isLoading, vm.isEmpty, !isOnline {
            OfflineHomeInfo()
        } else if let error = vm.error, vm.isEmpty, !vm.isLoading {
            EmptyStateView(
                systemImage: "exclamationmark.triangle",
                title: "Unable to Load",
                subtitle: LocalizedStringKey(error.displayMessage),
                action: .init(label: "Retry") { Task { await vm.load() } }
            )
        } else if vm.isEmpty && !vm.isLoading {
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
                    if vm.topPicks.isEmpty, vm.pendingSections.contains(.playlists) {
                        HomeShelfPlaceholder(title: "Top Picks for You", side: 250)
                    }
                    if !vm.topPicks.isEmpty {
                        MinidiscShelf {
                            MinidiscCarouselHeaderLink(
                                "Top Picks for You",
                                itemCount: vm.topPicks.count
                            ) {
                                PlaylistCarouselCollectionView(
                                    "Top Picks for You",
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
                    if !vm.recentlyPlayed.isEmpty {
                        MinidiscShelf {
                            MinidiscCarouselHeaderLink(
                                "Recently Played",
                                itemCount: vm.recentlyPlayed.count
                            ) {
                                AlbumCarouselCollectionView(
                                    "Recently Played",
                                    albums: vm.recentlyPlayed
                                )
                            }
                        } content: {
                            ForEach(Array(vm.recentlyPlayed.prefix(MinidiscCarouselMetrics.previewLimit))) { album in
                                AlbumShelfCard(album: album)
                            }
                        }
                    }
                    if vm.recentlyAdded.isEmpty, vm.pendingSections.contains(.recent) {
                        HomeShelfPlaceholder(title: "Recently Added", side: 160)
                    }
                    if !vm.recentlyAdded.isEmpty {
                        MinidiscShelf {
                            MinidiscCarouselHeaderLink(
                                "Recently Added",
                                itemCount: vm.recentlyAdded.count
                            ) {
                                AlbumCarouselCollectionView(
                                    "Recently Added",
                                    albums: vm.recentlyAdded
                                )
                            }
                        } content: {
                            ForEach(Array(vm.recentlyAdded.prefix(MinidiscCarouselMetrics.previewLimit))) { album in
                                AlbumShelfCard(album: album)
                            }
                        }
                    }
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
