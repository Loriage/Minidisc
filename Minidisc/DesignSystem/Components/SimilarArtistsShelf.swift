import SwiftUI
import SwiftSonic

/// "Similar Artists" carousel shared by the artist and album pages. In-library artists push the
/// artist page; out-of-library ones call `onOutOfLibraryTap` so the host can show the discovery sheet.
struct SimilarArtistsShelf: View {
    let recommendations: [SimilarArtistRecommendation]
    let imageURLs: [String: URL?]
    let isLoading: Bool
    let onOutOfLibraryTap: (SimilarArtistRecommendation) -> Void

    var body: some View {
        if isLoading {
            VStack(alignment: .leading, spacing: MinidiscSpacing.s) {
                MinidiscCarouselHeader("Similar Artists", showsChevron: false)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: MinidiscSpacing.m) {
                        ForEach(0..<6, id: \.self) { _ in
                            VStack(spacing: MinidiscSpacing.xs) {
                                SkeletonBlock(
                                    width: MinidiscCarouselMetrics.artistArtwork,
                                    height: MinidiscCarouselMetrics.artistArtwork,
                                    cornerRadius: MinidiscCarouselMetrics.artistArtwork / 2
                                )
                                SkeletonBlock(width: 96, height: 11, cornerRadius: 4)
                            }
                            .frame(width: MinidiscCarouselMetrics.artistArtwork)
                        }
                    }
                    .padding(.horizontal, MinidiscSpacing.l)
                }
            }
            .allowsHitTesting(false)
        } else {
            MinidiscShelf {
                MinidiscCarouselHeaderLink(
                    "Similar Artists",
                    itemCount: recommendations.count
                ) {
                    SimilarArtistsCollectionView(
                        recommendations: recommendations,
                        imageURLs: imageURLs
                    )
                }
            } content: {
                ForEach(Array(recommendations.prefix(MinidiscCarouselMetrics.previewLimit))) { recommendation in
                    ArtistRecommendationCard(
                        recommendation: recommendation,
                        imageURL: imageURLs[recommendation.id] ?? nil,
                        size: MinidiscCarouselMetrics.artistArtwork,
                        onOutOfLibraryTap: { onOutOfLibraryTap(recommendation) }
                    )
                }
            }
        }
    }
}

private struct ArtistRecommendationCard: View {
    let recommendation: SimilarArtistRecommendation
    let imageURL: URL?
    let size: CGFloat
    let onOutOfLibraryTap: () -> Void

    var body: some View {
        VStack {
            if recommendation.inLibrary {
                NavigationLink(value: HomeDestination.artist(
                    ArtistID3(
                        id: recommendation.id,
                        name: recommendation.name,
                        coverArt: recommendation.coverArt
                    )
                )) {
                    SimilarArtistCell(
                        recommendation: recommendation,
                        externalImageURL: imageURL,
                        size: size,
                        onOutOfLibraryTap: onOutOfLibraryTap
                    )
                }
                .buttonStyle(.plain)
            } else {
                SimilarArtistCell(
                    recommendation: recommendation,
                    externalImageURL: imageURL,
                    size: size,
                    onOutOfLibraryTap: onOutOfLibraryTap
                )
            }
        }
    }
}

private struct SimilarArtistsCollectionView: View {
    let recommendations: [SimilarArtistRecommendation]
    let imageURLs: [String: URL?]

    @Environment(\.appContainer) private var container
    @State private var selectedArtist: SimilarArtistRecommendation?

    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 170), spacing: MinidiscSpacing.l)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .center, spacing: MinidiscSpacing.l) {
                ForEach(recommendations) { recommendation in
                    ArtistRecommendationCard(
                        recommendation: recommendation,
                        imageURL: imageURLs[recommendation.id] ?? nil,
                        size: 132,
                        onOutOfLibraryTap: { selectedArtist = recommendation }
                    )
                }
            }
            .padding(MinidiscSpacing.l)
        }
        .minidiscContentWidth()
        .navigationTitle("Similar Artists")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedArtist) { recommendation in
            OutOfLibraryArtistSheet(
                artist: recommendation,
                imageURL: imageURLs[recommendation.id] ?? nil,
                providers: container?.externalProvidersStore.load() ?? []
            )
        }
    }
}
