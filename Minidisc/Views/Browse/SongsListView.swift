import SwiftUI
import SwiftSonic
import OSLog

/// Library-wide "All Songs" list. Pages the whole library (search3's empty-query wildcard) with a live
/// progress count, sorts off-main, and shows a Play/Shuffle-all header, a persisted sort control, and an
/// A–Z jump bar when sorted by title.
struct SongsListView: View {
    @Environment(\.appContainer) private var container
    @State private var songSelection: SongSelectionRequest?
    @State private var viewModel: SongsListViewModel?
    /// Persisted sort — Title by default, plus Artist / Recently Added / Release Date.
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
                .disabled(container?.serverState.isOnline != true || viewModel?.displaySongs.isEmpty != false)
            }
            ToolbarItem(placement: .primaryAction) {
                SongSortMenu(sort: $songSort)
                    .tint(.primary)
            }
        }
        .task(id: loadID) {
            guard let svc = container?.libraryService else { return }
            if viewModel == nil { viewModel = SongsListViewModel(libraryService: svc) }
            await viewModel?.load(sort: songSort)
        }
        .onChange(of: songSort) { _, newSort in
            Task { await viewModel?.changeSort(newSort) }
        }
    }

    @ViewBuilder
    private func content(_ vm: SongsListViewModel) -> some View {
        if vm.isLoading && vm.displaySongs.isEmpty {
            loadingProgress(vm)
        } else if container?.serverState.isOnline == false && vm.displaySongs.isEmpty {
            EmptyStateView(
                systemImage: "wifi.slash",
                title: "You're Offline",
                subtitle: "Connect to your server to browse all songs."
            )
        } else if let error = vm.error, vm.displaySongs.isEmpty {
            EmptyStateView(
                systemImage: "exclamationmark.triangle",
                title: "Unable to Load Songs",
                subtitle: LocalizedStringKey(error.displayMessage),
                action: .init(label: "Retry") { Task { await vm.load(sort: songSort) } }
            )
        } else if vm.displaySongs.isEmpty {
            EmptyStateView(
                systemImage: "music.note",
                title: "No Songs",
                subtitle: "Your library appears to be empty."
            )
        } else {
            songList(vm)
        }
    }

    /// Live count while the library pages in — so a large library shows progress, not a frozen spinner.
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
        let songs = vm.displaySongs
        return ScrollViewReader { proxy in
            List {
                if vm.didTruncate {
                    Text("Showing the first \(songs.count.formatted()) songs.")
                        .font(.minidiscCaption)
                        .foregroundStyle(.secondary)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                playShuffleHeader(songs)
                ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                    SongRow(song: song, index: index + 1, showCoverArt: true, isFavorite: isFavorite(song))
                        .contentShape(Rectangle())
                        .onTapGesture { play(songs, at: index) }
                        .id(song.id)
                }
            }
            .listStyle(.plain)
            .refreshable { await refresh(vm) }
            .safeAreaInset(edge: .trailing, spacing: 0) {
                // The A–Z jump bar only makes sense when sorted by title.
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

    @ViewBuilder
    private func playShuffleHeader(_ songs: [DisplayableSong]) -> some View {
        HStack(spacing: MinidiscSpacing.m) {
            Button {
                HapticFeedback.medium.trigger()
                Task {
                    guard !songs.isEmpty else { return }
                    await container?.toastService.perform { try await container?.playerService.play(tracks: songs, startIndex: 0) }
                }
            } label: {
                Label("Play", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, MinidiscSpacing.s)
            }

            Button {
                HapticFeedback.medium.trigger()
                Task {
                    guard !songs.isEmpty else { return }
                    let idx = Int.random(in: 0..<songs.count)
                    await container?.toastService.perform { try await container?.playerService.play(tracks: songs, startIndex: idx) }
                    if container?.playerState.isShuffled != true {
                        await container?.playerService.toggleShuffle()
                    }
                }
            } label: {
                Label("Shuffle", systemImage: "shuffle")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, MinidiscSpacing.s)
            }
        }
        .buttonStyle(.bordered)
        .tint(.minidiscAccent)
        .disabled(songs.isEmpty)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .padding(.vertical, 4)
    }

    private func isFavorite(_ song: DisplayableSong) -> Bool {
        container?.favoritesService.isFavorite(itemType: .song, itemId: song.id) == true
    }

    private func play(_ songs: [DisplayableSong], at index: Int) {
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

    private var loadID: ServerAccessSnapshot? {
        container?.serverState.accessSnapshot
    }

    private func refresh(_ viewModel: SongsListViewModel) async {
        if container?.serverState.isOnline == true {
            try? await container?.libraryCatalog.refreshTracks()
        }
        await viewModel.load(sort: songSort)
    }
}
