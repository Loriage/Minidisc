import SwiftUI
import SwiftSonic

struct AlbumCarouselCollectionView: View {
    private let title: Text
    private let albums: [AlbumID3]
    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 180), spacing: MinidiscSpacing.l)
    ]

    init(_ title: LocalizedStringResource, albums: [AlbumID3]) {
        self.title = Text(title)
        self.albums = albums
    }

    init(verbatim title: String, albums: [AlbumID3]) {
        self.title = Text(verbatim: title)
        self.albums = albums
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: MinidiscSpacing.l) {
                ForEach(albums) { album in
                    NavigationLink {
                        AlbumDetailView(album: album)
                    } label: {
                        AlbumGridCell(album: album)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(MinidiscSpacing.l)
        }
        .minidiscContentWidth()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct PlaylistCarouselCollectionView: View {
    private let title: Text
    private let playlists: [Playlist]
    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 180), spacing: MinidiscSpacing.l)
    ]

    init(_ title: LocalizedStringResource, playlists: [Playlist]) {
        self.title = Text(title)
        self.playlists = playlists
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: MinidiscSpacing.l) {
                ForEach(playlists) { playlist in
                    NavigationLink {
                        PlaylistDetailView(
                            playlist: playlist,
                            coverArtId: playlist.coverArt ?? playlist.id
                        )
                    } label: {
                        PlaylistCarouselGridCell(playlist: playlist)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(MinidiscSpacing.l)
        }
        .minidiscContentWidth()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PlaylistCarouselGridCell: View {
    let playlist: Playlist

    var body: some View {
        VStack(alignment: .leading, spacing: MinidiscSpacing.s) {
            GeometryReader { geometry in
                PlaylistCoverThumbnail(
                    playlistId: playlist.id,
                    serverId: nil,
                    coverArtId: playlist.coverArt ?? playlist.id,
                    title: playlist.name,
                    size: geometry.size.width
                )
            }
            .aspectRatio(1, contentMode: .fit)

            CoverCardMetadata(
                title: playlist.name,
                subtitle: String(localized: "\(playlist.songCount) tracks")
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
