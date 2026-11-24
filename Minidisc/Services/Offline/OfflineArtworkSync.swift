import Foundation
import Observation

@Observable
@MainActor
final class OfflineArtworkSync {
    struct Request: Equatable {
        let version: ServerConnection.Version?
        let serverID: UUID?
        let quality: ArtworkQuality
        let allowsCellular: Bool
        let canSynchronize: Bool
        let revision: Int
    }

    var isReady = false
    var revision = 0
    private(set) var isSyncing = false
    private let state: ServerState
    private let settings: CacheSettings
    private let downloads: any DownloadServiceProtocol
    private let artwork: ArtworkImageCache
    private let defaults: UserDefaults
    private var runID = UUID()

    var request: Request {
        Request(version: state.activeConnectionVersion, serverID: state.activeServer?.id,
                quality: settings.artworkQuality, allowsCellular: settings.cacheOverCellular,
                canSynchronize: isReady && state.hasObservedNetworkPath && state.isOnline
                    && !state.networkPathEvent.descriptor.isConstrained
                    && (!state.isExpensive || settings.cacheOverCellular), revision: revision)
    }

    init(state: ServerState, settings: CacheSettings, downloads: any DownloadServiceProtocol,
         artwork: ArtworkImageCache, defaults: UserDefaults = .standard) {
        self.state = state
        self.settings = settings
        self.downloads = downloads
        self.artwork = artwork
        self.defaults = defaults
    }

    func synchronize() async {
        let id = UUID()
        runID = id
        let expected = request
        isSyncing = false
        guard expected.canSynchronize, let serverID = expected.serverID else { return }
        isSyncing = true
        let repaired = await downloads.healMissingDownloadedCovers(
            serverID: serverID, allowsCellular: expected.allowsCellular
        ) { [weak self] in
            await MainActor.run { self?.request == expected }
        }
        guard runID == id else { return }
        isSyncing = false
        if repaired > 0 {
            artwork.clearCache()
            let key = "coverArtUploadVersion"
            defaults.set(defaults.integer(forKey: key) + 1, forKey: key)
        }
    }
}
