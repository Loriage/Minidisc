import SwiftUI
import SwiftSonic
import OSLog

struct FavoritesView: View {
    @Environment(\.appContainer) private var container
    @Environment(PlaylistAddition.self) private var playlistAddition
    @State private var viewModel: FavoritesViewModel?

    var body: some View {
        Group {
            if let vm = viewModel {
                content(vm)
            } else {
                LoadingStateView()
            }
        }
        .minidiscContentWidth()
        .navigationTitle("Favorites")
        .toolbarTitleDisplayMode(.inline)
        .onAppear {
            guard let svc = container?.libraryService else { return }
            if viewModel == nil { viewModel = FavoritesViewModel(libraryService: svc) }
        }
        .task { await viewModel?.load() }
    }

    @ViewBuilder
    private func content(_ vm: FavoritesViewModel) -> some View {
        let isEmpty = vm.songs.isEmpty && vm.albums.isEmpty && vm.artists.isEmpty
        if vm.isLoading && isEmpty {
            LoadingStateView()
        } else if let error = vm.error, isEmpty {
            EmptyStateView(
                systemImage: "exclamationmark.triangle",
                title: "Unable to Load Favorites",
                subtitle: LocalizedStringKey(error.displayMessage),
                action: .init(label: "Retry") { Task { await vm.load() } }
            )
        } else if isEmpty {
            EmptyStateView(
                systemImage: "star",
                title: "No favorites yet",
                subtitle: "Songs, albums, and artists you favorite will appear here."
            )
        } else {
            let displayableSongs = vm.songs.map { DisplayableSong(from: $0) }
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            let albums = AlbumSort.name.sorted(vm.albums)
            let artists = ArtistSort.name.sorted(vm.artists)
            let index = displayableSongs.map { AlphabetScrollEntry(id: "song:\($0.id)", name: $0.title) }
                + albums.map { AlphabetScrollEntry(id: "album:\($0.id)", name: $0.sortName ?? $0.name) }
                + artists.map { AlphabetScrollEntry(id: "artist:\($0.id)", name: $0.sortName ?? $0.name) }
            AlphabetIndexedContent(entries: index) {
                List {
                    songsSection(displayableSongs)
                    albumsSection(albums)
                    artistsSection(artists)
                }
                .listStyle(.plain)
                .refreshable { await vm.load() }
            }
        }
    }

    @ViewBuilder
    private func songsSection(_ songs: [DisplayableSong]) -> some View {
        if !songs.isEmpty {
            Section {
                // Same header as SongsListView — `.bordered` on both, so Play keeps its glyph and the
                // pair reads as one control rather than a primary/secondary split.
                HStack(spacing: MinidiscSpacing.m) {
                    Button {
                        HapticFeedback.medium.trigger()
                        Task {
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
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .padding(.vertical, 4)

                ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                    SongRow(song: song, index: index + 1, showCoverArt: true, isFavorite: true, onAddToPlaylist: playlistAddition.present)
                        .id("song:\(song.id)")
                        .accessibilityIdentifier("favorites.song.\(song.id)")
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

    @ViewBuilder
    private func albumsSection(_ albums: [AlbumID3]) -> some View {
        if !albums.isEmpty {
            Section("Albums") {
                ForEach(albums) { album in
                    NavigationLink(value: HomeDestination.album(album)) {
                        AlbumRow(
                            albumId: album.id,
                            name: album.name,
                            artist: album.artist,
                            year: album.year,
                            coverArtId: album.coverArt
                        )
                    }
                    .id("album:\(album.id)")
                }
            }
        }
    }

    @ViewBuilder
    private func artistsSection(_ artists: [ArtistID3]) -> some View {
        if !artists.isEmpty {
            Section("Artists") {
                ForEach(artists) { artist in
                    NavigationLink(value: HomeDestination.artist(artist)) {
                        ArtistRow(artist: artist)
                    }
                    .id("artist:\(artist.id)")
                }
            }
        }
    }
}
