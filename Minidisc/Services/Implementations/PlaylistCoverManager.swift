import Foundation
import OSLog

/// Stores playlist covers locally. Local-only by design: Navidrome does not take the uploaded image, so
/// the rendered cover (title baked in) lives in the app's artwork cache and is what every surface displays.
@MainActor
struct PlaylistCoverManager {
    private let downloadService: any DownloadServiceProtocol
    private let artworkImageCache: ArtworkImageCache

    init(
        downloadService: any DownloadServiceProtocol,
        artworkImageCache: ArtworkImageCache
    ) {
        self.downloadService = downloadService
        self.artworkImageCache = artworkImageCache
    }

    /// The id a surface must ask `CoverArtView` for when this playlist has a locally rendered cover. The
    /// server's `coverArt` id changes whenever the playlist is touched (rename, track add), so keying display
    /// on it would lose the local raster; the playlist id never moves.
    static func localCoverId(playlistId: String, downloadService: any DownloadServiceProtocol) async -> String? {
        let tieredId = "\(playlistId)@\(ArtworkTier.thumb.rawValue)"
        guard await downloadService.localCoverArtURL(forId: tieredId) != nil else { return nil }
        return playlistId
    }

    @discardableResult
    func applyGradientCover(_ spec: PlaylistGradientSpec, playlistId: String, title: String?, coverArtId: String?) async -> Data? {
        guard let data = PlaylistGradientRenderer.jpegData(for: spec, title: title) else {
            Logger.playlist.warning("PlaylistCoverManager: gradient render produced no data")
            return nil
        }
        await applyImageCover(data, playlistId: playlistId, coverArtId: coverArtId)
        return data
    }

    func applyImageCover(_ jpegData: Data, playlistId: String, coverArtId: String?) async {
        await cacheLocally(jpegData, playlistId: playlistId, coverArtId: coverArtId)
    }

    private func cacheLocally(_ data: Data, playlistId: String, coverArtId: String?) async {
        // Cache under both ids: surfaces ask CoverArtView for the server's coverArt id, which is not always
        // the playlist id, and a miss there falls through to the server's own (generated) art.
        for id in Set([playlistId, coverArtId].compactMap { $0 }) {
            // Invalidate before persisting so the new tier files survive.
            await artworkImageCache.invalidate(for: id)
            for tier in [ArtworkTier.thumb, .hero] {
                await downloadService.persistCover(data, forId: "\(id)@\(tier.rawValue)")
            }
        }
        let key = "coverArtUploadVersion"
        UserDefaults.standard.set(UserDefaults.standard.integer(forKey: key) + 1, forKey: key)
    }
}
