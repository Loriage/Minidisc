import SwiftUI

struct PlaylistFeaturedArtistsShelf: View {
    let artists: [FeaturedArtist]
    let onSelect: (FeaturedArtist) -> Void

    var body: some View {
        MinidiscShelf {
            MinidiscCarouselHeader("Featured Artists", showsChevron: false)
                .accessibilityAddTraits(.isHeader)
        } content: {
            ForEach(artists) { artist in
                Button {
                    onSelect(artist)
                } label: {
                    ArtistPortraitCell(name: artist.name, size: MinidiscCarouselMetrics.artistArtwork) {
                        FeaturedArtistAvatar(artist: artist, size: MinidiscCarouselMetrics.artistArtwork)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("playlist.featured.artist.\(artist.id)")
            }
        }
        .padding(.top, MinidiscSpacing.m)
    }
}
