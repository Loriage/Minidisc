import SwiftUI
import SwiftSonic

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
