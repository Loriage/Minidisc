import SwiftUI

/// One mood tile in Discover, presented like every other playlist in the app: the real server cover
/// on top, the name underneath. The cover is the gradient generated for the playlist, so a mood
/// looks the same here, in the playlists list, and in any other Subsonic client.
///
/// Rendered only once the mood has been synced at least once — DiscoverView filters on `playlistId`
/// first, so this never navigates to a playlist that does not exist yet.
struct MoodCard: View {
    let mood: Mood
    let playlistId: String

    private let cardSize: CGFloat = 140

    var body: some View {
        NavigationLink {
            PlaylistDetailView(playlistId: playlistId, name: String(localized: mood.title), coverArtId: playlistId)
        } label: {
            VStack(alignment: .leading, spacing: MinidiscSpacing.xs) {
                CoverArtCard(id: playlistId, size: cardSize, placeholderSystemImage: mood.symbolName)
                CoverCardMetadata(title: String(localized: mood.title))
            }
            .frame(width: cardSize, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: mood.title))
    }
}
