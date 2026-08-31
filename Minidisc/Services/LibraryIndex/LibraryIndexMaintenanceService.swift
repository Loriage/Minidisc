import Foundation
import SwiftSonic

nonisolated enum LibraryIndexMaintenanceProgress: Sendable, Equatable {
    case synchronizingMetadata
    case indexingRecommendations(completed: Int, total: Int)
}

nonisolated enum LibraryIndexMaintenanceError: LocalizedError, Equatable {
    case unmeteredNetworkRequired
    case repeatedRecommendationFailures

    var errorDescription: String? {
        switch self {
        case .unmeteredNetworkRequired:
            String(localized: "Full indexing requires an unmetered, unconstrained network connection.")
        case .repeatedRecommendationFailures:
            String(localized: "Indexing stopped after repeated recommendation failures. Your completed index data was kept.")
        }
    }
}

/// Coordinates the three user-visible maintenance actions for the complete, discardable
/// SwiftData library index. Recommendation indexing is deliberately sequential and resumable:
/// home servers are not flooded, and already-fresh albums are skipped on the next run.
actor LibraryIndexMaintenanceService {
    /// Matches the album screen's 10-card shelf plus enough headroom for artist filtering.
    static let recommendationLimit = 20
    static let largeLibraryAlbumThreshold = 500

    private let serverService: any ServerServiceProtocol
    private let store: LibraryIndexStore
    private let synchronizer: LibraryIndexSynchronizer
    private let libraryService: LibraryService

    init(
        serverService: any ServerServiceProtocol,
        store: LibraryIndexStore,
        synchronizer: LibraryIndexSynchronizer,
        libraryService: LibraryService
    ) {
        self.serverService = serverService
        self.store = store
        self.synchronizer = synchronizer
        self.libraryService = libraryService
    }

    func usage() async throws -> LibraryIndexStorageUsage {
        try await store.storageUsage()
    }

    func activeServerAlbumCount() async throws -> Int {
        let serverID = try await serverService.activeConnection().version.serverID
        return try await store.counts(for: serverID).albums
    }

    /// Deletes only the dedicated metadata/recommendation index. Downloads, favorites,
    /// playback history, server configuration, and the stream cache live in other stores.
    func eraseAll() async throws {
        await synchronizer.cancelAll()
        try await store.eraseAll()
    }

    /// Refreshes every metadata family for the active server: artists, albums, tracks, playlists.
    func synchronize() async throws {
        let serverID = try await serverService.activeConnection().version.serverID
        try await synchronizer.refreshAll(serverID: serverID)
    }

    /// Synchronizes all metadata, then precomputes album recommendations one request at a time.
    /// The run can be cancelled at any point; rows already committed remain valid and are skipped
    /// for seven days when the operation resumes.
    func indexFullServer(
        progress: @escaping @MainActor @Sendable (LibraryIndexMaintenanceProgress) -> Void
    ) async throws {
        let allowed = await MainActor.run {
            let state = serverService.state
            let path = state.networkPathEvent.descriptor
            return state.hasObservedNetworkPath
                && path.isOnline
                && !path.isExpensive
                && !path.isConstrained
        }
        guard allowed else { throw LibraryIndexMaintenanceError.unmeteredNetworkRequired }

        await progress(.synchronizingMetadata)
        let serverID = try await serverService.activeConnection().version.serverID
        try await synchronizer.refreshAll(serverID: serverID)
        try Task.checkCancellation()

        let albums = try await store.albums(serverID: serverID)
        let cutoff = Date.now.addingTimeInterval(-LibraryService.albumRecommendationCacheLifetime)
        let alreadyIndexed = try await store.freshRecommendationAlbumIDs(
            serverID: serverID,
            refreshedAfter: cutoff,
            minimumRequestedLimit: Self.recommendationLimit
        )

        var completed = albums.lazy.filter { alreadyIndexed.contains($0.id) }.count
        let total = albums.count
        await progress(.indexingRecommendations(completed: completed, total: total))

        var consecutiveFailures = 0
        for album in albums where !alreadyIndexed.contains(album.id) {
            try Task.checkCancellation()
            do {
                _ = try await libraryService.refreshAlbumRecommendations(
                    to: album.id,
                    excludingArtistID: album.artistId,
                    excludingArtistName: album.artist,
                    limit: Self.recommendationLimit,
                    serverID: serverID
                )
                consecutiveFailures = 0
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                consecutiveFailures += 1
                if consecutiveFailures >= 3 {
                    throw LibraryIndexMaintenanceError.repeatedRecommendationFailures
                }
            }

            completed += 1
            await progress(.indexingRecommendations(completed: completed, total: total))
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
