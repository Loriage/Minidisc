import SwiftUI
import SwiftData
import SwiftSonic
import OSLog

struct AlbumsListView: View {
    @Environment(\.appContainer) private var container
    @State private var viewModel: AlbumListViewModel?
    @AppStorage("minidisc.albumSort") private var albumSort: AlbumSort = .recentlyAdded
    @AppStorage("minidisc.albumListGrid") private var gridLayout = false

    private func displayedAlbums(_ vm: AlbumListViewModel) -> [AlbumID3] {
        container?.serverState.isOnline == false ? container?.offlineLibrary.snapshot.albums ?? [] : vm.albums
    }
    private func sortedAlbums(_ vm: AlbumListViewModel) -> [AlbumID3] { albumSort.sorted(displayedAlbums(vm)) }

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
            if container?.serverState.isOnline == true { await viewModel?.load() }
        }
    }

    @ViewBuilder
    private func content(_ vm: AlbumListViewModel) -> some View {
        if container?.serverState.isOnline != false && vm.isLoading && displayedAlbums(vm).isEmpty {
            LoadingStateView()
        } else if container?.serverState.isOnline == false && displayedAlbums(vm).isEmpty {
            OfflineBrowsingEmptyView()
        } else if let error = vm.error, displayedAlbums(vm).isEmpty {
            EmptyStateView(
                systemImage: "exclamationmark.triangle",
                title: "Unable to Load Albums",
                subtitle: LocalizedStringKey(error.displayMessage),
                action: .init(label: "Retry") { Task { await vm.load() } }
            )
        } else if displayedAlbums(vm).isEmpty {
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
        AlbumSort.name.sorted(displayedAlbums(vm)).map { AlphabetScrollEntry(id: $0.id, name: $0.sortName ?? $0.name) }
    }

    private var loadID: ServerAccessSnapshot? {
        container?.serverState.accessSnapshot
    }

    private func refresh(_ viewModel: AlbumListViewModel) async {
        if container?.serverState.isOnline == true {
            _ = try? await container?.libraryCatalog.refreshAlbums()
        }
        if container?.serverState.isOnline == true { await viewModel.load() }
        else { await container?.offlineLibrary.refresh() }
    }

}
