import SwiftUI

enum PlaylistDownloadControl {
    case download, downloadMissing, cancel, remove

    var symbol: String {
        switch self {
        case .download, .downloadMissing: "arrow.down"
        case .cancel: "xmark"
        case .remove: "checkmark"
        }
    }

    var label: LocalizedStringKey {
        switch self {
        case .download: "Download Playlist"
        case .downloadMissing: "Download Missing Tracks"
        case .cancel: "Cancel Download"
        case .remove: "Remove Download"
        }
    }
}

/// Shuffle · Play · Download for playlist pages, as the same round buttons used on albums and artists.
struct PlaylistPlaybackControls: View {
    let isEnabled: Bool
    /// Kept for call-site compatibility; the round play button follows the foreground style.
    let playColor: Color
    let downloadControl: PlaylistDownloadControl?
    let onPlay: () -> Void
    let onShuffle: () -> Void
    let onDownload: () -> Void

    var body: some View {
        HStack(spacing: MinidiscSpacing.xl) {
            Button("Shuffle", systemImage: "shuffle", action: onShuffle)
                .buttonStyle(.minidiscCircle(diameter: MinidiscControlSize.large))
                .accessibilityIdentifier("playlist.detail.shuffle")

            Button("Play", systemImage: "play.fill", action: onPlay)
                .buttonStyle(.minidiscCircle(diameter: MinidiscControlSize.large, isProminent: true))
                .accessibilityIdentifier("playlist.detail.play")

            Button(action: onDownload) {
                Image(systemName: (downloadControl ?? .download).symbol)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.minidiscCircle(diameter: MinidiscControlSize.large))
            .disabled(downloadControl == nil)
            .accessibilityLabel((downloadControl ?? .download).label)
            .accessibilityIdentifier("playlist.detail.download")
        }
        .foregroundStyle(.white)
        .disabled(!isEnabled)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, MinidiscSpacing.xxl)
    }
}
