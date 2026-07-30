import SwiftUI

/// Rebrand playlist cover thumbnail for the library surfaces (iOS). Always RASTER: gradient covers are
/// rendered once (title baked in) and cached by `PlaylistCoverManager`, so every surface just shows the
/// stored image — no live `MeshGradient` per cell.
///
/// A locally rendered cover is keyed on the playlist id, never on the server's `coverArt` id (which changes
/// on every rename / track edit), and wins over the server artwork. Re-resolved on the shared
/// `coverArtUploadVersion` bump — the signal every cover change already emits. 12pt continuous corners.
struct PlaylistCoverThumbnail: View {
    let playlistId: String
    let serverId: UUID?
    /// Server cover id, used when this playlist has no locally rendered cover.
    let coverArtId: String
    let title: String
    let size: CGFloat

    @Environment(\.appContainer) private var container
    @AppStorage("coverArtUploadVersion") private var coverArtUploadVersion = 0
    @State private var localCoverId: String?

    var body: some View {
        CoverArtView(id: localCoverId ?? coverArtId, size: Int(size * 2))
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: MinidiscCornerRadius.large, style: .continuous))
            .task(id: "\(playlistId):\(coverArtUploadVersion)") {
                guard let downloadService = container?.downloadService else { return }
                localCoverId = await PlaylistCoverManager.localCoverId(
                    playlistId: playlistId,
                    downloadService: downloadService
                )
            }
    }
}
