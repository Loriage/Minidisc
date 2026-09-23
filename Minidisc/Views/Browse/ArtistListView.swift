import SwiftUI
import SwiftData
import SwiftSonic

struct ArtistListView: View {
    @Environment(\.appContainer) private var container
    @State private var viewModel: ArtistListViewModel?
    @AppStorage("minidisc.artistSort") private var artistSort: ArtistSort = .name
    @AppStorage("minidisc.artistListGrid") private var gridLayout = false

    private let gridColumns = [GridItem(.adaptive(minimum: 110, maximum: 180), spacing: MinidiscSpacing.l)]

    var body: some View {
        Group {
            if let vm = viewModel {
                browseContent(vm)
            } else {
                LoadingStateView()
            }
        }
        .minidiscContentWidth()
        .navigationTitle("Artists")
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ArtistSortMenu(sort: $artistSort)
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
                .accessibilityIdentifier("browse.artists.layout")
            }
        }
        .task(id: loadID) {
            guard let svc = container?.libraryService else { return }
            if viewModel == nil { viewModel = ArtistListViewModel(libraryService: svc) }
            if container?.serverState.isOnline == true { await viewModel?.load() }
        }
    }

    private func displayedArtists(_ vm: ArtistListViewModel) -> [ArtistID3] {
        container?.serverState.isOnline == false ? container?.offlineLibrary.snapshot.artists ?? [] : vm.indexes.flatMap(\.artist)
    }

    @ViewBuilder
    private func browseContent(_ vm: ArtistListViewModel) -> some View {
        if container?.serverState.isOnline != false && vm.isLoading && displayedArtists(vm).isEmpty {
            LoadingStateView()
        } else if container?.serverState.isOnline == false && displayedArtists(vm).isEmpty {
            OfflineBrowsingEmptyView()
        } else if let error = vm.error, displayedArtists(vm).isEmpty {
            EmptyStateView(
                systemImage: "exclamationmark.triangle",
                title: "Unable to Load Artists",
                subtitle: LocalizedStringKey(error.displayMessage),
                action: .init(label: "Retry") { Task { await vm.load() } }
            )
        } else if displayedArtists(vm).isEmpty {
            EmptyStateView(
                systemImage: "music.mic",
                title: "No Artists",
                subtitle: "Your library appears to be empty."
            )
        } else if gridLayout {
            artistsGrid(vm)
        } else {
            flatList(vm)
        }
    }

    private func flatList(_ vm: ArtistListViewModel) -> some View {
        AlphabetIndexedContent(entries: artistIndex(vm), prepareJump: { artistSort = .name }) {
            List(artistSort.sorted(displayedArtists(vm))) { artist in
                NavigationLink(value: HomeDestination.artist(artist)) {
                    ArtistRow(artist: artist)
                }
                .id(artist.id)
                .accessibilityIdentifier("browse.artist.\(artist.id)")
            }
            .listStyle(.plain)
            .refreshable { await refresh(vm) }
        }
    }

    private func artistsGrid(_ vm: ArtistListViewModel) -> some View {
        AlphabetIndexedContent(entries: artistIndex(vm), prepareJump: { artistSort = .name }) {
            ScrollView {
                LazyVGrid(columns: gridColumns, spacing: MinidiscSpacing.l) {
                    ForEach(artistSort.sorted(displayedArtists(vm))) { artist in
                        NavigationLink(value: HomeDestination.artist(artist)) {
                            ArtistGridCard(artist: artist)
                        }
                        .buttonStyle(.plain)
                        .id(artist.id)
                        .accessibilityIdentifier("browse.artist.\(artist.id)")
                    }
                }
                .padding(MinidiscSpacing.l)
            }
            .refreshable { await refresh(vm) }
        }
    }

    private func artistIndex(_ vm: ArtistListViewModel) -> [AlphabetScrollEntry] {
        ArtistSort.name.sorted(displayedArtists(vm)).map { AlphabetScrollEntry(id: $0.id, name: $0.sortName ?? $0.name) }
    }

    private var loadID: ServerAccessSnapshot? {
        container?.serverState.accessSnapshot
    }

    private func refresh(_ viewModel: ArtistListViewModel) async {
        if container?.serverState.isOnline == true {
            _ = try? await container?.libraryCatalog.refreshArtists()
        }
        if container?.serverState.isOnline == true { await viewModel.load() }
        else { await container?.offlineLibrary.refresh() }
    }
}

nonisolated struct OfflineAlbumSummary: Sendable, Identifiable, Hashable {
    let albumId: String
    let albumName: String
    let artistName: String?
    let coverArtId: String?
    let trackCount: Int
    var id: String { albumId }
}

nonisolated struct OfflineArtistSummary: Sendable, Identifiable, Hashable {
    let name: String
    let albums: [OfflineAlbumSummary]
    /// Server artist id when the downloaded tracks carried one. Present → the row can open the real
    /// artist screen (which rebuilds itself from downloads); absent → it falls back to the flat album list.
    var artistId: String?
    var coverArtId: String?
    var id: String { artistId ?? name }
}

struct OfflineArtistAlbumsView: View {
    let artist: OfflineArtistSummary

    var body: some View {
        List {
            ForEach(artist.albums) { album in
                NavigationLink(value: HomeDestination.offlineAlbum(album)) {
                    AlbumRow(
                        albumId: album.albumId,
                        name: album.albumName,
                        artist: album.artistName,
                        year: nil,
                        coverArtId: album.coverArtId
                    )
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(artist.name)
        .navigationBarTitleDisplayModeInline()
        .minidiscContentWidth()
    }
}
