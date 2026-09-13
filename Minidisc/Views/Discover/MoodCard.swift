import SwiftUI

/// Discover uses dedicated mood artwork, independent of the server's album collage.
/// The destination still follows the reconciled server playlist reference.
struct MoodCard: View {
    let mood: Mood
    let playlistId: String
    let coverArtId: String?

    private let cardSize: CGFloat = 140

    var body: some View {
        NavigationLink {
            PlaylistDetailView(playlistId: playlistId, name: String(localized: mood.title), coverArtId: coverArtId)
        } label: {
            VStack(alignment: .leading, spacing: MinidiscSpacing.xs) {
                MoodArtwork(mood: mood)
                    .frame(width: cardSize, height: cardSize)
                    .minidiscCoverStyle()
                CoverCardMetadata(title: String(localized: mood.title))
            }
            .frame(width: cardSize, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("mood-card-\(mood.rawValue)")
        .accessibilityLabel(String(localized: mood.title))
    }
}
