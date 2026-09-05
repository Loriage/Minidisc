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

struct PlaylistPlaybackControls: View {
    let isEnabled: Bool
    let playColor: Color
    let downloadControl: PlaylistDownloadControl?
    let onPlay: () -> Void
    let onShuffle: () -> Void
    let onDownload: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .callout) private var scaledControlSize: CGFloat = 48
    @ScaledMetric(relativeTo: .callout) private var scaledPlayWidth: CGFloat = 160

    private var controlSize: CGFloat { min(scaledControlSize, 64) }

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: MinidiscSpacing.l))
            : AnyLayout(HStackLayout(spacing: MinidiscSpacing.l))

        layout {
            Button(action: onShuffle) {
                Image(systemName: "shuffle")
                    .font(.minidiscCellTitle)
                    .foregroundStyle(.white)
                    .frame(width: controlSize, height: controlSize)
                    .background(.white.opacity(0.1), in: Circle())
                    .contentShape(Circle())
            }
            .accessibilityLabel("Shuffle")
            .accessibilityIdentifier("playlist.detail.shuffle")

            PlayButton(
                action: onPlay,
                isDisabled: !isEnabled,
                accentColor: .white,
                labelColor: playColor,
                height: dynamicTypeSize.isAccessibilitySize ? nil : controlSize
            )
            .frame(maxWidth: scaledPlayWidth)
            .accessibilityIdentifier("playlist.detail.play")

            if let downloadControl {
                Button(action: onDownload) {
                    Image(systemName: downloadControl.symbol)
                        .font(.minidiscCellTitle)
                        .foregroundStyle(.white)
                        .frame(width: controlSize, height: controlSize)
                        .background(.white.opacity(0.1), in: Circle())
                        .contentShape(Circle())
                }
                .accessibilityLabel(downloadControl.label)
                .accessibilityIdentifier("playlist.detail.download")
            }
        }
        .buttonStyle(.borderless)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, MinidiscSpacing.xxl)
    }
}
