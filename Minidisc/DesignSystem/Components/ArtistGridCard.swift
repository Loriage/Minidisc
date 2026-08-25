import SwiftUI
import SwiftSonic

/// Adaptive grid cell for the artists browse surface.
/// Mirrors AlbumGridCell: square cover art, artist name, album count.
struct ArtistGridCard: View {
    let artist: ArtistID3

    var body: some View {
        VStack(alignment: .leading, spacing: MinidiscSpacing.s) {
            GeometryReader { geo in
                CoverArtView(
                    id: artist.coverArt ?? artist.id,
                    size: Int(geo.size.width * 2),
                    placeholderSystemImage: "person.fill"
                )
                .frame(width: geo.size.width, height: geo.size.width)
                .minidiscCoverStyle(cornerRadius: MinidiscCornerRadius.standard)
            }
            .aspectRatio(1, contentMode: .fit)

            CoverCardMetadata(
                title: artist.name,
                subtitle: artist.albumCount.map { String(localized: "\($0) albums") }
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
