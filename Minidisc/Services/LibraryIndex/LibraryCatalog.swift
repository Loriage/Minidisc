import Foundation
import OSLog
import SwiftSonic

/// Local-first catalogue used by browsing and search. The server remains authoritative,
/// but a completed index answers repeated reads without network access.
actor LibraryCatalog {
    private static let fallbackRefreshInterval: TimeInterval = 7 * 24 * 60 * 60

    private let source: any LibraryRemoteSource
    private let store: LibraryIndexStore
    private let synchronizer: LibraryIndexSynchronizer

    init(
        source: any LibraryRemoteSource,
        store: LibraryIndexStore,
        synchronizer: LibraryIndexSynchronizer
    ) {
        self.source = source
        self.store = store
        self.synchronizer = synchronizer
    }

    /// Performs background index work only on a network path that the app has identified as
    /// unmetered. Explicit pull-to-refresh operations remain available on every online path.
    func prepare(automaticRefreshAllowed: Bool = true, now: Date = .now) async throws {
        guard automaticRefreshAllowed else { return }
        let serverID = try await source.activeServerID()
        let status = try await store.status(for: serverID)
        let remoteStatus: LibraryRemoteScanStatus?

        do {
            remoteStatus = try await source.scanStatus(serverID: serverID)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard Self.canServeStaleData(after: error) else { throw error }
            remoteStatus = nil
            Logger.library.debug(
                "Library index: scan status unavailable; using age-based refresh: \(error, privacy: .public)"
            )
        }

        // Reading while the server mutates its catalogue can mix two server generations.
        // Keep the previous local generation and retry after a later launch, path change,
        // or explicit refresh.
        guard remoteStatus?.isScanning != true else {
            Logger.library.debug("Library index: server scan in progress; automatic refresh deferred")
            return
        }

        if !status.isComplete {
            try await synchronizer.prepare(
                serverID: serverID,
                sourceWatermark: remoteStatus?.lastCompletedAt
            )
            return
        }

        guard shouldRefresh(status: status, remoteStatus: remoteStatus, now: now) else { return }
        try await synchronizer.refreshAll(
            serverID: serverID,
            sourceWatermark: remoteStatus?.lastCompletedAt
        )
    }

    func refreshAlbums() async throws -> [AlbumID3] {
        let serverID = try await source.activeServerID()
        try await synchronizer.refreshAlbums(serverID: serverID)
        return try await store.albums(serverID: serverID)
    }

    func refreshArtists() async throws -> [ArtistIndex] {
        let serverID = try await source.activeServerID()
        try await synchronizer.refreshArtists(serverID: serverID)
        return try await store.artists(serverID: serverID)
    }

    func refreshTracks() async throws {
        let serverID = try await source.activeServerID()
        try await synchronizer.refreshTracks(serverID: serverID)
    }

    func refreshPlaylists() async throws -> [Playlist] {
        let serverID = try await source.activeServerID()
        try await synchronizer.refreshPlaylists(serverID: serverID)
        return try await store.playlists(serverID: serverID)
    }

    func search(_ query: String) async throws -> SearchResult3 {
        let serverID = try await source.activeServerID()
        let completion = try await store.status(for: serverID)
        let local = try await store.search(query, serverID: serverID)
        let isOnline = await source.isOnline()

        if completion.libraryIsComplete, !local.isEmpty || !isOnline {
            return try Self.searchResult(from: local)
        }
        guard isOnline else {
            if !local.isEmpty { return try Self.searchResult(from: local) }
            throw URLError(.notConnectedToInternet)
        }

        do {
            let remote = try await source.search(query, serverID: serverID)
            let generation = "opportunistic-\(UUID().uuidString)"
            do {
                try await store.upsertArtists(
                    (remote.artist ?? []).map { (Self.indexName(for: $0.name), $0) },
                    serverID: serverID,
                    generation: generation,
                    preserveExistingGeneration: true
                )
                try await store.upsertAlbums(
                    remote.album ?? [],
                    serverID: serverID,
                    generation: generation,
                    preserveExistingGeneration: true
                )
                try await store.upsertTracks(
                    remote.song ?? [],
                    serverID: serverID,
                    generation: generation,
                    serverOrderStart: nil,
                    preserveExistingGeneration: true
                )
            } catch {
                Logger.library.debug(
                    "Library index: could not cache remote search results: \(error, privacy: .public)"
                )
            }
            return remote
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard Self.canServeStaleData(after: error), !local.isEmpty else { throw error }
            Logger.library.info("Library index: serving partial local search after remote failure")
            return try Self.searchResult(from: local)
        }
    }

    func artists() async throws -> [ArtistIndex] {
        let serverID = try await source.activeServerID()
        let completion = try await store.status(for: serverID)
        let local = try await store.artists(serverID: serverID)
        if completion.artists { return local }
        guard await source.isOnline() else {
            if !local.isEmpty { return local }
            throw URLError(.notConnectedToInternet)
        }

        do {
            try await synchronizer.refreshArtists(serverID: serverID)
            return try await store.artists(serverID: serverID)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let fallback = try await store.artists(serverID: serverID)
            if Self.canServeStaleData(after: error), !fallback.isEmpty { return fallback }
            throw error
        }
    }

    func artist(id: String) async throws -> ArtistID3 {
        let serverID = try await source.activeServerID()
        let completion = try await store.status(for: serverID)
        let local = try await store.artist(id: id, serverID: serverID)
        if completion.artists && completion.albums, let local { return local }
        if !(await source.isOnline()) {
            if let local { return local }
            throw URLError(.notConnectedToInternet)
        }

        do {
            let remote = try await source.artist(id: id, serverID: serverID)
            let generation = "opportunistic-\(UUID().uuidString)"
            try await store.upsertArtists(
                [(Self.indexName(for: remote.name), remote)],
                serverID: serverID,
                generation: generation,
                preserveExistingGeneration: true
            )
            if let albums = remote.album {
                try await store.upsertAlbums(
                    albums,
                    serverID: serverID,
                    generation: generation,
                    preserveExistingGeneration: true
                )
            }
            return remote
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Self.canServeStaleData(after: error), let local { return local }
            throw error
        }
    }

    func albums() async throws -> [AlbumID3] {
        let serverID = try await source.activeServerID()
        let completion = try await store.status(for: serverID)
        let local = try await store.albums(serverID: serverID)
        if completion.albums { return local }
        guard await source.isOnline() else {
            if !local.isEmpty { return local }
            throw URLError(.notConnectedToInternet)
        }

        do {
            try await synchronizer.refreshAlbums(serverID: serverID)
            return try await store.albums(serverID: serverID)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let fallback = try await store.albums(serverID: serverID)
            if Self.canServeStaleData(after: error), !fallback.isEmpty { return fallback }
            throw error
        }
    }

    func album(id: String) async throws -> AlbumID3 {
        let serverID = try await source.activeServerID()
        let completion = try await store.status(for: serverID)
        let local = try await store.album(id: id, serverID: serverID)
        if completion.albums && completion.tracks,
           let local,
           local.song != nil || local.songCount == 0 {
            return local
        }
        if !(await source.isOnline()) {
            if let local { return local }
            throw URLError(.notConnectedToInternet)
        }

        do {
            let remote = try await source.album(id: id, serverID: serverID)
            let generation = "opportunistic-\(UUID().uuidString)"
            try await store.upsertAlbums(
                [remote],
                serverID: serverID,
                generation: generation,
                preserveExistingGeneration: true
            )
            if let songs = remote.song {
                try await store.upsertTracks(
                    songs,
                    serverID: serverID,
                    generation: generation,
                    serverOrderStart: nil,
                    preserveExistingGeneration: true
                )
            }
            return remote
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Self.canServeStaleData(after: error), let local { return local }
            throw error
        }
    }

    func recentlyAddedAlbums(size: Int) async throws -> [AlbumID3] {
        let serverID = try await source.activeServerID()
        let completion = try await store.status(for: serverID)
        let local = try await store.recentlyAddedAlbums(serverID: serverID, limit: size)
        let hasLocalSnapshot = completion.albums || !local.isEmpty
        if !(await source.isOnline()) {
            if hasLocalSnapshot { return local }
            throw URLError(.notConnectedToInternet)
        }
        do {
            // A complete index can still describe the previous scan. Home needs this small,
            // current page even while the rest of the catalogue is refreshing in the background.
            return try await source.recentlyAddedAlbums(size: size, serverID: serverID)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Self.canServeStaleData(after: error), hasLocalSnapshot { return local }
            throw error
        }
    }

    func songs(offset: Int, count: Int) async throws -> [Song] {
        let serverID = try await source.activeServerID()
        let completion = try await store.status(for: serverID)
        let local = try await store.songs(serverID: serverID, offset: offset, count: count)
        if completion.tracks || local.count == count { return local }
        if !(await source.isOnline()) {
            if !local.isEmpty { return local }
            throw URLError(.notConnectedToInternet)
        }

        do {
            let remote = try await source.songsPage(
                offset: offset,
                count: count,
                serverID: serverID
            )
            try await store.upsertTracks(
                remote,
                serverID: serverID,
                generation: "opportunistic-\(UUID().uuidString)",
                serverOrderStart: offset,
                preserveExistingGeneration: true
            )
            return remote
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Self.canServeStaleData(after: error), !local.isEmpty { return local }
            throw error
        }
    }

    func playlists() async throws -> [Playlist] {
        let serverID = try await source.activeServerID()
        let local = try await store.playlists(serverID: serverID)
        guard await source.isOnline() else {
            if !local.isEmpty { return local }
            throw URLError(.notConnectedToInternet)
        }

        do {
            try await synchronizer.refreshPlaylists(serverID: serverID)
            return try await store.playlists(serverID: serverID)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let fallback = try await store.playlists(serverID: serverID)
            if Self.canServeStaleData(after: error), !fallback.isEmpty { return fallback }
            throw error
        }
    }

    func cachedPlaylist(id: String) async -> PlaylistWithSongs? {
        guard let serverID = try? await source.activeServerID() else { return nil }
        return try? await store.playlist(id: id, serverID: serverID)?.playlist
    }

    func playlist(id: String) async throws -> PlaylistWithSongs {
        try await loadPlaylist(id: id, forceRefresh: false)
    }

    func refreshPlaylist(id: String) async throws -> PlaylistWithSongs {
        try await loadPlaylist(id: id, forceRefresh: true)
    }

    private func loadPlaylist(id: String, forceRefresh: Bool) async throws -> PlaylistWithSongs {
        let serverID = try await source.activeServerID()
        let local = try await store.playlist(id: id, serverID: serverID)
        if !forceRefresh, let local, local.isCurrent { return local.playlist }
        guard await source.isOnline() else {
            if !forceRefresh, let local { return local.playlist }
            throw URLError(.notConnectedToInternet)
        }

        do {
            let remote = try await source.playlist(id: id, serverID: serverID)
            try Task.checkCancellation()
            guard try await source.activeServerID() == serverID else { throw CancellationError() }
            do {
                try await store.cachePlaylistDetail(remote, serverID: serverID)
            } catch {
                Logger.library.debug(
                    "Library index: could not cache playlist detail: \(error, privacy: .public)"
                )
            }
            return remote
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if PlaylistAvailability.isConfirmedMissing(error) {
                // Preserve audio and offline ownership; remove only discardable metadata.
                try? await store.removePlaylist(id: id, serverID: serverID)
            }
            if !forceRefresh, Self.canServeStaleData(after: error), let local { return local.playlist }
            throw error
        }
    }

    /// Records the values already confirmed by a successful mutation, then marks the list
    /// generation incomplete so the next uncached list read reconciles server-owned fields.
    func recordPlaylistMutation(
        summary: Playlist?,
        detail: PlaylistWithSongs?,
        deletedID: String? = nil
    ) async {
        do {
            let serverID = try await source.activeServerID()
            if let summary {
                try await store.cachePlaylistSummary(summary, serverID: serverID)
            }
            if let detail {
                try await store.cachePlaylistDetail(detail, serverID: serverID)
            }
            if let deletedID {
                try await store.removePlaylist(id: deletedID, serverID: serverID)
            }
            try await store.markPlaylistsIncomplete(serverID: serverID)
        } catch {
            // The server mutation already succeeded. A discardable index write must never turn
            // that domain success into a user-visible failure.
            Logger.library.debug(
                "Library index: could not record playlist mutation: \(error, privacy: .public)"
            )
        }
        await MainActor.run {
            NotificationCenter.default.post(name: .minidiscPlaylistsChanged, object: nil)
        }
    }

    /// `nil` means the index is not complete enough to build an authoritative queue.
    func songs(artistID: String) async throws -> [Song]? {
        let serverID = try await source.activeServerID()
        guard try await store.status(for: serverID).tracks else { return nil }
        return try await store.songs(artistID: artistID, serverID: serverID)
    }

    func findArtist(byName name: String) async -> ArtistID3? {
        do {
            let serverID = try await source.activeServerID()
            let local = try await store.artist(named: name, serverID: serverID)
            let completion = try await store.status(for: serverID)
            if completion.artists || local != nil { return local }
            try await synchronizer.refreshArtists(serverID: serverID)
            return try await store.artist(named: name, serverID: serverID)
        } catch is CancellationError {
            return nil
        } catch {
            Logger.library.debug("Library index: artist lookup failed: \(error, privacy: .public)")
            return nil
        }
    }

    nonisolated static func canServeStaleData(after error: any Error) -> Bool {
        if error is LibraryIndexError { return true }
        if let sonicError = error as? SwiftSonicError { return sonicError.isTransient }
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .notConnectedToInternet,
             .networkConnectionLost,
             .timedOut,
             .cannotConnectToHost,
             .dnsLookupFailed,
             .cannotFindHost,
             .dataNotAllowed,
             .internationalRoamingOff:
            return true
        default:
            return false
        }
    }

    private func shouldRefresh(
        status: LibraryIndexStatus,
        remoteStatus: LibraryRemoteScanStatus?,
        now: Date
    ) -> Bool {
        guard let librarySyncedAt = status.librarySyncedAt else { return true }

        if let remoteCompletedAt = remoteStatus?.lastCompletedAt {
            return remoteCompletedAt > librarySyncedAt
        }

        // Plain Subsonic servers often omit scan timestamps. A weekly fallback bounds
        // staleness without repeatedly walking very large libraries.
        return now.timeIntervalSince(librarySyncedAt) >= Self.fallbackRefreshInterval
    }

    private static func indexName(for artistName: String) -> String {
        guard let first = LibraryIndexText.normalized(artistName).first else { return "#" }
        let value = String(first).uppercased()
        return value.range(of: "^[A-Z]$", options: .regularExpression) == nil ? "#" : value
    }

    private struct EncodedSearchResult: Encodable {
        let artist: [ArtistID3]
        let album: [AlbumID3]
        let song: [Song]
    }

    private static func searchResult(from result: LibraryIndexSearchResults) throws -> SearchResult3 {
        let payload = EncodedSearchResult(
            artist: result.artists,
            album: result.albums,
            song: result.songs
        )
        return try JSONDecoder().decode(SearchResult3.self, from: JSONEncoder().encode(payload))
    }
}
