import SwiftUI

/// One mood tile in Discover, presented like every other playlist in the app: the real server cover
/// on top, the name underneath. The cover is the gradient generated for the playlist, so a mood
/// looks the same here, in the playlists list, and in any other Subsonic client.
///
/// Discover reconciles these references with the server independently of playlist generation.
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
                CoverArtCard(id: coverArtId ?? playlistId, size: cardSize, placeholderSystemImage: mood.symbolName)
                CoverCardMetadata(title: String(localized: mood.title))
            }
            .frame(width: cardSize, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("mood-card-\(mood.rawValue)")
        .accessibilityLabel(String(localized: mood.title))
    }
}
