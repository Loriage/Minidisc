import SwiftUI
import SwiftSonic

struct HomeResumeCard: View {
    let onOpenPlayer: () -> Void
    @Environment(\.appContainer) private var container

    var body: some View {
        if let state = container?.playerState, let song = state.currentTrack, !state.isLiveStream {
            VStack(alignment: .leading, spacing: MinidiscSpacing.s) {
                Text(state.wantsPlayback ? LocalizedStringResource("Now Playing") : LocalizedStringResource("Continue Listening"))
                    .font(.minidiscShelfTitle)
                HStack(spacing: MinidiscSpacing.m) {
                    Button(action: onOpenPlayer) {
                        HStack(spacing: MinidiscSpacing.m) {
                            CoverArtView(id: song.coverArtId ?? song.id, size: 112)
                                .frame(width: 56, height: 56)
                                .minidiscCoverStyle(cornerRadius: MinidiscCornerRadius.standard)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(song.title).font(.headline).lineLimit(2)
                                if let artist = song.artist {
                                    Text(artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Text("\(max(0, state.queue.count - state.currentIndex)) songs in your queue")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("home.resume.open")
                    Button {
                        HapticFeedback.light.trigger()
                        Task { await container?.playerService.togglePlayPause() }
                    } label: {
                        Image(systemName: state.wantsPlayback ? "pause.fill" : "play.fill")
                            .font(.title2)
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(state.wantsPlayback ? "Pause" : "Resume")
                    .accessibilityIdentifier("home.resume.playPause")
                }
                if state.duration > 0 {
                    ProgressView(value: min(max(state.position, 0), state.duration), total: state.duration)
                        .tint(Color.minidiscAccent)
                        .accessibilityLabel("Playback progress")
                }
            }
            .padding(MinidiscSpacing.m)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: MinidiscCornerRadius.standard))
            .padding(.horizontal, MinidiscSpacing.l)
        }
    }
}

struct HomeFavoriteSongsSection: View {
    let songs: [Song]
    @Environment(\.appContainer) private var container
    @Environment(PlaylistAddition.self) private var playlistAddition

    var body: some View {
        if !songs.isEmpty {
            VStack(alignment: .leading, spacing: MinidiscSpacing.s) {
                NavigationLink(value: HomeDestination.libraryFavorites) {
                    HStack {
                        Text("Your Favorite Songs").font(.minidiscShelfTitle)
                        Spacer()
                        Image(systemName: "chevron.right").font(.headline).foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                let tracks = songs.map { DisplayableSong(from: $0) }
                ForEach(Array(tracks.prefix(3).enumerated()), id: \.element.id) { index, song in
                    SongRow(song: song, index: index + 1, showCoverArt: true, isFavorite: true, trailingAccessory: .menu,
                            onAddToPlaylist: playlistAddition.present, onTap: {
                        Task {
                            await container?.toastService.perform {
                                try await container?.playerService.play(tracks: tracks, startIndex: index)
                            }
                        }
                    })
                }
            }
            .padding(.horizontal, MinidiscSpacing.l)
            .accessibilityIdentifier("home.favoriteSongs")
        }
    }
}

struct HomeAlbumSection: View {
    let title: LocalizedStringResource
    let albums: [AlbumID3]
    var identifier: String = ""

    var body: some View {
        if !albums.isEmpty {
            MinidiscShelf {
                MinidiscCarouselHeaderLink(title, itemCount: albums.count) {
                    AlbumCarouselCollectionView(title, albums: albums)
                }
            } content: {
                ForEach(Array(albums.prefix(MinidiscCarouselMetrics.previewLimit))) { album in
                    AlbumShelfCard(album: album)
                }
            }
            .accessibilityIdentifier(identifier)
        }
    }
}
