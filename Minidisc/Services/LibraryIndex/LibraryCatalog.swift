import Foundation
import OSLog
import SwiftSonic

/// Local-first catalogue used by browsing and search. The server remains authoritative,
/// but a completed index answers repeated reads without network access.
actor LibraryCatalog {
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

    func prepare() async throws {
        let serverID = try await source.activeServerID()
        try await synchronizer.prepare(serverID: serverID)
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

    func search(_ query: String) async throws -> SearchResult3 {
        let serverID = try await source.activeServerID()
        let completion = try await store.completion(for: serverID)
        let local = try await store.search(query, serverID: serverID)
        let isOnline = await source.isOnline()

        if completion.isComplete, !local.isEmpty || !isOnline {
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
            guard !local.isEmpty else { throw error }
            Logger.library.info("Library index: serving partial local search after remote failure")
            return try Self.searchResult(from: local)
        }
    }

    func artists() async throws -> [ArtistIndex] {
        let serverID = try await source.activeServerID()
        let completion = try await store.completion(for: serverID)
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
            if !fallback.isEmpty { return fallback }
            throw error
        }
    }

    func artist(id: String) async throws -> ArtistID3 {
        let serverID = try await source.activeServerID()
        let completion = try await store.completion(for: serverID)
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
            if let local { return local }
            throw error
        }
    }

    func albums() async throws -> [AlbumID3] {
        let serverID = try await source.activeServerID()
        let completion = try await store.completion(for: serverID)
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
            if !fallback.isEmpty { return fallback }
            throw error
        }
    }

    func album(id: String) async throws -> AlbumID3 {
        let serverID = try await source.activeServerID()
        let completion = try await store.completion(for: serverID)
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
            if let local { return local }
            throw error
        }
    }

    func recentlyAddedAlbums(size: Int) async throws -> [AlbumID3] {
        let serverID = try await source.activeServerID()
        let completion = try await store.completion(for: serverID)
        if completion.albums {
            return try await store.recentlyAddedAlbums(serverID: serverID, limit: size)
        }
        if !(await source.isOnline()) {
            let local = try await store.recentlyAddedAlbums(serverID: serverID, limit: size)
            if !local.isEmpty { return local }
            throw URLError(.notConnectedToInternet)
        }
        do {
            return try await source.recentlyAddedAlbums(size: size, serverID: serverID)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let local = try await store.recentlyAddedAlbums(serverID: serverID, limit: size)
            if !local.isEmpty { return local }
            throw error
        }
    }

    func songs(offset: Int, count: Int) async throws -> [Song] {
        let serverID = try await source.activeServerID()
        let completion = try await store.completion(for: serverID)
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
            if !local.isEmpty { return local }
            throw error
        }
    }

    /// `nil` means the index is not complete enough to build an authoritative queue.
    func songs(artistID: String) async throws -> [Song]? {
        let serverID = try await source.activeServerID()
        guard try await store.completion(for: serverID).tracks else { return nil }
        return try await store.songs(artistID: artistID, serverID: serverID)
    }

    func findArtist(byName name: String) async -> ArtistID3? {
        do {
            let serverID = try await source.activeServerID()
            let local = try await store.artist(named: name, serverID: serverID)
            let completion = try await store.completion(for: serverID)
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
