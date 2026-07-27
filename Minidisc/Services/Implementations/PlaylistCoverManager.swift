import Foundation
import SwiftSonic
import OSLog

/// Stores playlist covers locally and uploads them to Navidrome when available.
@MainActor
struct PlaylistCoverManager {
    private let serverState: ServerState
    private let serverService: any ServerServiceProtocol
    private let downloadService: any DownloadServiceProtocol
    private let artworkImageCache: ArtworkImageCache

    init(
        serverState: ServerState,
        serverService: any ServerServiceProtocol,
        downloadService: any DownloadServiceProtocol,
        artworkImageCache: ArtworkImageCache
    ) {
        self.serverState = serverState
        self.serverService = serverService
        self.downloadService = downloadService
        self.artworkImageCache = artworkImageCache
    }

    @discardableResult
    func applyGradientCover(_ spec: PlaylistGradientSpec, playlistId: String) async -> Data? {
        guard let data = PlaylistGradientRenderer.jpegData(for: spec) else {
            Logger.playlist.warning("PlaylistCoverManager: gradient render produced no data")
            return nil
        }
        await applyImageCover(data, playlistId: playlistId)
        return data
    }

    func applyImageCover(_ jpegData: Data, playlistId: String) async {
        await cacheLocally(jpegData, playlistId: playlistId)
        await uploadIfPossible(jpegData, playlistId: playlistId)
    }

    private func cacheLocally(_ data: Data, playlistId: String) async {
        // Invalidate before persisting so the new tier files survive.
        await artworkImageCache.invalidate(for: playlistId)
        for tier in [ArtworkTier.thumb, .hero] {
            await downloadService.persistCover(data, forId: "\(playlistId)@\(tier.rawValue)")
        }
        let key = "coverArtUploadVersion"
        UserDefaults.standard.set(UserDefaults.standard.integer(forKey: key) + 1, forKey: key)
    }

    private func uploadIfPossible(_ jpegData: Data, playlistId: String) async {
        guard let snapshot = serverState.activeServer,
              let baseURL = URL(string: snapshot.baseURL) else { return }
        do {
            let creds = try await serverService.activeCredentials()
            let api = NavidromeNativeAPI(transport: CustomHeadersTransport(headers: creds.customHeaders))
            let token = try await api.authenticate(
                baseURL: baseURL,
                username: snapshot.username,
                password: creds.password
            )
            try await api.uploadPlaylistCover(
                baseURL: baseURL,
                token: token,
                playlistId: playlistId,
                imageData: jpegData,
                mimeType: "image/jpeg"
            )
            Logger.playlist.debug("PlaylistCoverManager: uploaded cover for \(playlistId, privacy: .public)")
        } catch {
            Logger.playlist.warning("PlaylistCoverManager: cover upload skipped (local cache stands): \(error)")
        }
    }
}
