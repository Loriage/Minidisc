import SwiftUI
import SwiftData
import SwiftSonic
import OSLog

struct SongsListView: View {
    @Environment(\.appContainer) private var container
    private var isOnline: Bool { container?.serverState.activeServer != nil && container?.serverState.isOnline == true }
    @State private var songSelection: SongSelectionRequest?
    @State private var viewModel: SongsListViewModel?
    @AppStorage("minidisc.songSort") private var songSort: SongSort = .title

    var body: some View {
        Group {
            if let vm = viewModel {
                content(vm)
            } else {
                LoadingStateView()
            }
        }
        .minidiscContentWidth()
        .navigationTitle("Songs")
        .toolbarTitleDisplayMode(.inline)
        .sheet(item: $songSelection) { SongSelectionSheet(request: $0) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Select Songs", systemImage: "checkmark.circle") {
                    songSelection = SongSelectionRequest(songs: viewModel?.displaySongs ?? [])
                }
                .disabled(!isOnline || viewModel?.displaySongs.isEmpty != false)
            }
            ToolbarItem(placement: .primaryAction) {
                SongSortMenu(sort: $songSort)
                    .tint(.primary)
            }
        }
        .task(id: loadID) {
            guard let svc = container?.libraryService else { return }
            if viewModel == nil { viewModel = SongsListViewModel(libraryService: svc) }
            if isOnline { await viewModel?.load(sort: songSort) }
        }
        .onChange(of: songSort) { _, newSort in
            Task { await viewModel?.changeSort(newSort) }
        }
    }

    private func displayedSongs(_ vm: SongsListViewModel) -> [DisplayableSong] {
        let server = !isOnline ? container?.offlineLibrary.snapshot.songs ?? [] : vm.displaySongs
        let songs = server + (container?.localMusic.catalog.songs ?? [])
        let byID = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return songSort.sorted(songs.map { $0.asSong() }).compactMap { byID[$0.id] }
    }

    @ViewBuilder
    private func content(_ vm: SongsListViewModel) -> some View {
        if isOnline && vm.isLoading && displayedSongs(vm).isEmpty {
            loadingProgress(vm)
        } else if container?.serverState.activeServer != nil && !isOnline && displayedSongs(vm).isEmpty {
            OfflineBrowsingEmptyView()
        } else if let error = vm.error, displayedSongs(vm).isEmpty {
            EmptyStateView(
                systemImage: "exclamationmark.triangle",
                title: "Unable to Load Songs",
                subtitle: LocalizedStringKey(error.displayMessage),
                action: .init(label: "Retry") { Task { await vm.load(sort: songSort) } }
            )
        } else if displayedSongs(vm).isEmpty {
            EmptyStateView(
                systemImage: "music.note",
                title: "No Songs",
                subtitle: "Your library appears to be empty."
            )
        } else {
            songList(vm)
        }
    }

    private func loadingProgress(_ vm: SongsListViewModel) -> some View {
        VStack(spacing: MinidiscSpacing.m) {
            ProgressView()
            Text(vm.loadedCount == 0 ? "Loading songs…" : "\(vm.loadedCount.formatted()) songs loaded…")
                .font(.minidiscBody)
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .animation(.easeInOut, value: vm.loadedCount)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func songList(_ vm: SongsListViewModel) -> some View {
        let songs = displayedSongs(vm)
        return ScrollViewReader { proxy in
            List {
                if isOnline && vm.didTruncate {
                    Text("Showing the first \(songs.count.formatted()) songs.")
                        .font(.minidiscCaption)
                        .foregroundStyle(.secondary)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                playShuffleHeader(songs)
                SongListFavoriteRows(songs: songs, serverID: container?.serverState.activeServer?.id) { index in
                    play(songs, at: index)
                }
            }
            .listStyle(.plain)
            .refreshable { await refresh(vm) }
            .safeAreaInset(edge: .trailing, spacing: 0) {
                if songSort == .title && songs.count >= 20 {
                    AlphabetJumpBar(
                        availableLetters: songs.availableAlphabetLetters(keyPath: \.title),
                        onLetterTap: { letter in
                            if let id = firstAlphabetItemID(forLetter: letter, in: songs, keyPath: \.title) {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    proxy.scrollTo(id, anchor: .top)
                                }
                            }
                        }
                    )
                    .padding(.trailing, 4)
                }
            }
        }
    }

    private func playShuffleHeader(_ songs: [DisplayableSong]) -> some View {
        HStack(spacing: MinidiscSpacing.m) {
            Button { play(songs, order: .ordered) } label: {
                Label("Play", systemImage: "play.fill")
                    .frame(maxWidth: .infinity).padding(.vertical, MinidiscSpacing.s)
            }
            Button { play(songs, order: .shuffled) } label: {
                Label("Shuffle", systemImage: "shuffle")
                    .frame(maxWidth: .infinity).padding(.vertical, MinidiscSpacing.s)
            }
            .accessibilityIdentifier("library.songs.shuffle")
        }
        .buttonStyle(.bordered)
        .tint(.minidiscAccent)
        .disabled(container?.localMusic.catalog.playable(songs).isEmpty != false)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .padding(.vertical, 4)
    }

    private func play(_ songs: [DisplayableSong], at index: Int? = nil,
                      order: PreparedPlaybackQueue.Order = .ordered) {
        guard let container else { return }
        let playable = container.localMusic.catalog.playable(songs)
        let selected = index.map { songs[$0] }
        Task {
            await container.toastService.perform {
                if let selected, !playable.contains(where: { $0.id == selected.id }) { throw LocalMusicError.unavailable }
                guard !playable.isEmpty else { throw LocalMusicError.unavailable }
                try await container.playerService.play(preparingQueue: {
                    PreparedPlaybackQueue(tracks: playable,
                        startIndex: selected.flatMap { selected in playable.firstIndex { $0.id == selected.id } } ?? 0,
                        order: order)
                })
            }
        }
    }

    private var loadID: ServerAccessSnapshot? {
        container?.serverState.accessSnapshot
    }

    private func refresh(_ viewModel: SongsListViewModel) async {
        if isOnline {
            try? await container?.libraryCatalog.refreshTracks()
        }
        if isOnline { await viewModel.load(sort: songSort) }
        else { await container?.offlineLibrary.refresh() }
        await container?.localMusic.refresh()
    }
}

/// One server-scoped fetch for the list; no synchronous store access in row builders.
private struct SongListFavoriteRows: View {
    @Environment(\.appContainer) private var container
    let songs: [DisplayableSong]
    let onPlay: (Int) -> Void
    @Query private var favorites: [FavoriteRecord]

    init(songs: [DisplayableSong], serverID: UUID?, onPlay: @escaping (Int) -> Void) {
        self.songs = songs
        self.onPlay = onPlay
        if let serverID {
            _favorites = Query(filter: #Predicate<FavoriteRecord> {
                $0.serverId == serverID && $0.itemType == "song"
            })
        } else {
            _favorites = Query(filter: #Predicate<FavoriteRecord> { _ in false })
        }
    }

    var body: some View {
        let favoriteIDs = Set(favorites.map(\.itemId))
        ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
            SongRow(song: song, index: index + 1, showCoverArt: true,
                    secondaryText: song.isLocalFile && container?.localMusic.catalog.availableSongIDs.contains(song.id) != true
                        ? String(localized: "Unavailable on this device", table: "LocalMusic") : nil,
                    isFavorite: favoriteIDs.contains(song.id))
                .contentShape(Rectangle())
                .onTapGesture { onPlay(index) }
                .id(song.id)
        }
    }
}
