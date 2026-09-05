import SwiftUI

struct SimilarArtistCell: View {
    let recommendation: SimilarArtistRecommendation
    let externalImageURL: URL?
    var size: CGFloat = 140
    let onOutOfLibraryTap: () -> Void

    var body: some View {
        if recommendation.inLibrary {
            cellContent
        } else {
            Button(action: onOutOfLibraryTap) {
                cellContent
            }
            .buttonStyle(.plain)
        }
    }

    private var cellContent: some View {
        ArtistPortraitCell(name: recommendation.name, size: size) {
            if recommendation.inLibrary, let coverArt = recommendation.coverArt {
                CoverArtView(id: coverArt, size: Int(size * 2), placeholderSystemImage: "person.fill")
            } else {
                ExternalCoverView(url: externalImageURL) {
                    ArtistPlaceholderView(name: recommendation.name, size: size)
                }
            }
        }
    }
}

/// Shared presentation for Similar Artists and the artists featured in a playlist.
/// Each caller retains its own artwork resolution and navigation.
struct ArtistPortraitCell<Portrait: View>: View {
    let name: String
    let size: CGFloat
    @ViewBuilder let portrait: () -> Portrait

    var body: some View {
        VStack(spacing: MinidiscSpacing.s) {
            portrait()
                .frame(width: size, height: size)
                .clipShape(Circle())

            Text(name)
                .font(.minidiscCaption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .frame(width: size)
    }
}
