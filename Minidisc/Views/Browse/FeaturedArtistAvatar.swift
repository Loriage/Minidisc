import SwiftUI
import SwiftSonic

/// Shows the album cover until a matching artist photo is loaded.
/// Resolve through the shared artist index and verify identity before swapping.
struct FeaturedArtistAvatar: View {
    let artist: FeaturedArtist
    var size: CGFloat = MinidiscCarouselMetrics.artistArtwork

    @Environment(\.appContainer) private var container
    @State private var resolvedArtistCoverArt: String?

    private var albumCoverId: String { artist.coverArtId ?? artist.id }

    var body: some View {
        CoverArtView(
            id: resolvedArtistCoverArt ?? albumCoverId,
            size: Int(size * 2),
            placeholderSystemImage: "music.mic"
        )
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: artist.id) {
            await resolveArtistPhoto()
        }
    }

    private func resolveArtistPhoto() async {
        guard resolvedArtistCoverArt == nil, let container else { return }
        // Name → ArtistID3 via the shared, build-once index; verify the id to be collision-safe.
        guard let match = await container.libraryService.findArtist(byName: artist.name),
              match.id == artist.id,
              let coverArt = match.coverArt,
              coverArt != albumCoverId else { return }
        // Only swap once the photo actually loads — so a photoless artist keeps the album cover, no flash.
        guard await container.artworkImageCache.load(coverArtId: coverArt, tier: .thumb) != nil else { return }
        resolvedArtistCoverArt = coverArt
    }
}
