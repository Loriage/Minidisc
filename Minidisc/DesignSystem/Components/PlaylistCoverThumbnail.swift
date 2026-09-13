import SwiftUI

/// Local covers use playlist IDs because server cover IDs change after edits.
/// PlaylistCoverManager caches rendered gradients; cells only display the raster image.
struct PlaylistCoverThumbnail: View {
    let playlistId: String
    let serverId: UUID?
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
