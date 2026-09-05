import SwiftUI
import SwiftData
import SwiftSonic
import OSLog

struct AlbumsListView: View {
    @Environment(\.appContainer) private var container
    @State private var viewModel: AlbumListViewModel?
    /// Shared album ordering, persisted and reused by the artist discography too.
    @AppStorage("minidisc.albumSort") private var albumSort: AlbumSort = .recentlyAdded
    /// List vs grid layout. Defaults to list.
    @AppStorage("minidisc.albumListGrid") private var gridLayout = false

    /// Albums in the user's chosen order (client-side, so switching sort never re-fetches).
    private func sortedAlbums(_ vm: AlbumListViewModel) -> [AlbumID3] { albumSort.sorted(vm.albums) }

    var body: some View {
        Group {
            if let vm = viewModel {
                content(vm)
            } else {
                LoadingStateView()
            }
        }
        .minidiscContentWidth()
        .navigationTitle("Albums")
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                AlbumSortMenu(sort: $albumSort)
                    .tint(.primary)
            }
            ToolbarItem(placement: .primaryAction) {
                Button(
                    gridLayout ? "List view" : "Grid view",
                    systemImage: gridLayout ? "list.bullet" : "square.grid.2x2"
                ) {
                    gridLayout.toggle()
                }
                .tint(.primary)
                .accessibilityIdentifier("browse.albums.layout")
            }
        }
        .task(id: loadID) {
            Logger.boot.notice("🟢 AlbumsListView task fired — activeServer=\(String(describing: container?.serverState.activeServer?.baseURL), privacy: .public) isOnline=\(String(describing: container?.serverState.isOnline), privacy: .public)")
            guard let svc = container?.libraryService else {
                Logger.boot.error("🔴 AlbumsListView: container?.libraryService is nil — skipping")
                return
            }
            if viewModel == nil { viewModel = AlbumListViewModel(libraryService: svc) }
            await viewModel?.load()
        }
    }

    @ViewBuilder
    private func content(_ vm: AlbumListViewModel) -> some View {
        if vm.isLoading && vm.albums.isEmpty {
            LoadingStateView()
        } else if container?.serverState.isOnline == false && vm.albums.isEmpty {
            if let serverId = container?.serverState.activeServer?.id {
                OfflineAlbumsContent(serverId: serverId)
            } else {
                EmptyStateView(
                    systemImage: "wifi.slash",
                    title: "You're Offline",
                    subtitle: "Connect to your server to browse albums."
                )
            }
        } else if let error = vm.error, vm.albums.isEmpty {
            EmptyStateView(
                systemImage: "exclamationmark.triangle",
                title: "Unable to Load Albums",
                subtitle: LocalizedStringKey(error.displayMessage),
                action: .init(label: "Retry") { Task { await vm.load() } }
            )
        } else if vm.albums.isEmpty {
            EmptyStateView(
                systemImage: "square.stack",
                title: "No Albums",
                subtitle: "Your library appears to be empty."
            )
        } else if gridLayout {
            albumsGrid(vm)
        } else {
            albumsList(vm)
        }
    }

    /// A letter jump also selects name ordering, keeping the index and rows consistent.
    @ViewBuilder
    private func albumsList(_ vm: AlbumListViewModel) -> some View {
        let albums = sortedAlbums(vm)
        AlphabetIndexedContent(entries: albumIndex(vm), prepareJump: { albumSort = .name }) {
            List(albums) { album in
                NavigationLink(value: HomeDestination.album(album)) {
                    AlbumRow(
                        albumId: album.id,
                        name: album.name,
                        artist: album.artist,
                        year: album.year,
                        coverArtId: album.coverArt
                    )
                }
                .id(album.id)
                .accessibilityIdentifier("browse.album.\(album.id)")
            }
            .listStyle(.plain)
            .refreshable { await refresh(vm) }
        }
    }

    /// Grid of AlbumGridCell — adaptive column count.
    @ViewBuilder
    private func albumsGrid(_ vm: AlbumListViewModel) -> some View {
        AlphabetIndexedContent(entries: albumIndex(vm), prepareJump: { albumSort = .name }) {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110, maximum: 180), spacing: MinidiscSpacing.l)], spacing: MinidiscSpacing.l) {
                    ForEach(sortedAlbums(vm)) { album in
                        NavigationLink(value: HomeDestination.album(album)) {
                            AlbumGridCell(album: album)
                        }
                        .buttonStyle(.plain)
                        .id(album.id)
                        .accessibilityIdentifier("browse.album.\(album.id)")
                    }
                }
                .padding(MinidiscSpacing.l)
            }
            .refreshable { await refresh(vm) }
        }
    }

    private func albumIndex(_ vm: AlbumListViewModel) -> [AlphabetScrollEntry] {
        AlbumSort.name.sorted(vm.albums).map { AlphabetScrollEntry(id: $0.id, name: $0.sortName ?? $0.name) }
    }

    private var loadID: ServerAccessSnapshot? {
        container?.serverState.accessSnapshot
    }

    private func refresh(_ viewModel: AlbumListViewModel) async {
        if container?.serverState.isOnline == true {
            _ = try? await container?.libraryCatalog.refreshAlbums()
        }
        await viewModel.load()
    }

}

// MARK: - Offline Albums

private struct OfflineAlbumsContent: View {
    let serverId: UUID
    @Query private var albums: [DownloadedAlbum]
    @Query private var tracks: [DownloadedTrack]

    init(serverId: UUID) {
        self.serverId = serverId
        let sid = serverId
        _albums = Query(
            filter: #Predicate<DownloadedAlbum> { album in album.serverId == sid },
            sort: [SortDescriptor(\DownloadedAlbum.name)]
        )
        _tracks = Query(filter: #Predicate<DownloadedTrack> { track in track.serverId == sid })
    }

    private var displayAlbums: [DownloadedAlbumDisplay] {
        DownloadedAlbumMerger.merge(records: albums, tracks: tracks)
    }

    var body: some View {
        if displayAlbums.isEmpty {
            EmptyStateView(
                systemImage: "wifi.slash",
                title: "You're Offline",
                subtitle: "No downloaded albums available. Download albums while online to listen offline."
            )
        } else {
            AlphabetIndexedContent(entries: displayAlbums.map { AlphabetScrollEntry(id: $0.id, name: $0.name) }) {
                List {
                    Section("Downloaded Albums") {
                        ForEach(displayAlbums) { display in
                            NavigationLink(value: HomeDestination.downloadedAlbum(display)) {
                                AlbumRow(
                                    albumId: display.albumId,
                                    name: display.name,
                                    artist: display.artist,
                                    year: nil,
                                    coverArtId: display.coverArtId
                                )
                            }
                            .id(display.id)
                            .accessibilityIdentifier("browse.album.\(display.albumId)")
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }
}
