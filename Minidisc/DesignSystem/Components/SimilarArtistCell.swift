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
        VStack(spacing: MinidiscSpacing.s) {
            if recommendation.inLibrary, let coverArt = recommendation.coverArt {
                CoverArtView(id: coverArt, size: Int(size * 2), placeholderSystemImage: "person.fill")
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                ExternalCoverView(url: externalImageURL) {
                    ArtistPlaceholderView(name: recommendation.name, size: size)
                }
                .frame(width: size, height: size)
                .clipShape(Circle())
            }

            Text(recommendation.name)
                .font(.minidiscCaption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .frame(width: size)
    }
}
