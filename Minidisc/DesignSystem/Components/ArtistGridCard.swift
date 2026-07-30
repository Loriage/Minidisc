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

            VStack(alignment: .leading, spacing: MinidiscSpacing.xs) {
                Text(artist.name)
                    .font(.minidiscCellTitle)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let count = artist.albumCount {
                    Text("\(count) albums")
                        .font(.minidiscCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
