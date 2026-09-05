import SwiftUI
import SwiftSonic

/// Compact album card for horizontal-scroll discover surfaces.
/// Keeps cover art, album name and artist together, with wider cards for accessibility text.
struct AlbumCard: View {
    let album: AlbumID3

    @Environment(\.appContainer) private var container
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var cardSize: CGFloat { dynamicTypeSize.isAccessibilitySize ? 260 : 140 }

    var body: some View {
        VStack(alignment: .leading, spacing: MinidiscSpacing.xs) {
            CoverArtCard(id: album.coverArt ?? album.id, size: cardSize)
            CoverCardMetadata(title: album.name, subtitle: album.artist)
        }
        .frame(width: cardSize)
        .lazyCollectionContextMenu(
            itemType: .album,
            itemId: album.id,
            displayName: album.name,
            displaySubtitle: album.artist ?? "",
            coverArtId: album.coverArt,
            favoriteType: .album,
            songLoader: {
                guard let c = container else { return [] }
                let loaded = try await c.libraryService.album(id: album.id)
                return (loaded.song ?? []).map { DisplayableSong(from: $0, isDownloaded: false) }
            }
        )
    }
}

/// The 160pt album card used by Home-style shelves.
struct AlbumShelfCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let album: AlbumID3
    var metadataSubtitle: String? = nil

    private var side: CGFloat { dynamicTypeSize.isAccessibilitySize ? 260 : 160 }

    var body: some View {
        NavigationLink(value: HomeDestination.album(album)) {
            VStack(alignment: .leading, spacing: MinidiscSpacing.xs) {
                CoverArtView(id: album.coverArt ?? album.id, size: Int(side * 2))
                    .frame(width: side, height: side)
                    .minidiscCoverStyle(cornerRadius: MinidiscCornerRadius.standard)
                CoverCardMetadata(
                    title: album.name,
                    subtitle: metadataSubtitle ?? album.artist
                )
            }
            .frame(width: side, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}
