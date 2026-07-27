// Minidisc — Music client for Subsonic/OpenSubsonic servers
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftSonic

/// An artist avatar card (circular cover + name + album count) for the artists grid.
/// The circle fills the cell width up to a cap, so it adapts to different column counts.
struct ArtistGridCard: View {
    let artist: ArtistID3

    var body: some View {
        VStack(spacing: MinidiscSpacing.s) {
            CoverArtView(
                id: artist.coverArt ?? artist.id,
                size: 280,
                placeholderSystemImage: "person.fill"
            )
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 150)
            .clipShape(Circle())
            .shadow(color: .black.opacity(0.18), radius: 8, y: 4)

            Text(artist.name)
                .font(.minidiscCellTitle)
                .lineLimit(1)
                .multilineTextAlignment(.center)

            if let count = artist.albumCount {
                Text("\(count) albums")
                    .font(.minidiscCaption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
