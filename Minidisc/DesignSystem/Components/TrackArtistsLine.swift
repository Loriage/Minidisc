import SwiftUI

/// The tappable artist credits under a track title ("Gorillaz, Dennis Hopper, Ajay Prasanna").
/// Tapping opens the artist directly when there is one credit, or the artist picker when there are several.
struct TrackArtistsLine: View {
    let credits: [ArtistCredit]
    var accessibilityIdentifier: String = ""
    let onTap: () -> Void

    var body: some View {
        // The button hugs the text so only the names themselves are a link; the rest of the row plays.
        Button(action: onTap) {
            Text(verbatim: credits.map(\.name).formatted(.list(type: .and, width: .narrow)))
                .font(.minidiscCellSubtitle)
                .foregroundStyle(Color.minidiscAccent)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(Text("Artists: \(credits.map(\.name).formatted(.list(type: .and)))"))
        .accessibilityHint(credits.count > 1 ? Text("Choose an artist to open") : Text("Opens the artist"))
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
