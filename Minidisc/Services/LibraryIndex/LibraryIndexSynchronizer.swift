import Foundation
import OSLog
import SwiftSonic

/// Performs bounded, sequential scans of a self-hosted server. Each entity type is
/// committed independently; cancellation or failure never deletes the previous generation.
actor LibraryIndexSynchronizer {
    private struct SyncKey: Hashable, Sendable {
        let serverID: UUID
        let kind: LibraryIndexKind
    }

    private let source: any LibraryRemoteSource
    private let store: LibraryIndexStore
    private let albumPageSize: Int
    private let songPageSize: Int
    private var inFlight: [SyncKey: Task<Void, Error>] = [:]

    init(
        source: any LibraryRemoteSource,
        store: LibraryIndexStore,
        albumPageSize: Int = 500,
        songPageSize: Int = 1_000
    ) {
        self.source = source
        self.store = store
        self.albumPageSize = albumPageSize
        self.songPageSize = songPageSize
    }

    func prepare(serverID: UUID) async throws {
        let completion = try await store.completion(for: serverID)
        var firstFailure: (any Error)?

        if !completion.artists {
            do {
                try await refreshArtists(serverID: serverID)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                firstFailure = error
            }
        }
        if !completion.albums {
            do {
                try await refreshAlbums(serverID: serverID)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if firstFailure == nil { firstFailure = error }
            }
        }
        if !completion.tracks {
            do {
                try await refreshTracks(serverID: serverID)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if firstFailure == nil { firstFailure = error }
            }
        }

        if let firstFailure { throw firstFailure }
    }

    func refreshArtists(serverID: UUID) async throws {
        let key = SyncKey(serverID: serverID, kind: .artists)
        if let existing = inFlight[key] {
            return try await existing.value
        }
        let source = source
        let store = store
        let task = Task {
            try await Self.syncArtists(source: source, store: store, serverID: serverID)
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        try await task.value
    }

    func refreshAlbums(serverID: UUID) async throws {
        let key = SyncKey(serverID: serverID, kind: .albums)
        if let existing = inFlight[key] {
            return try await existing.value
        }
        let source = source
        let store = store
        let pageSize = albumPageSize
        let task = Task {
            try await Self.syncAlbums(
                source: source,
                store: store,
                serverID: serverID,
                pageSize: pageSize
            )
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        try await task.value
    }

    func refreshTracks(serverID: UUID) async throws {
        let key = SyncKey(serverID: serverID, kind: .tracks)
        if let existing = inFlight[key] {
            return try await existing.value
        }
        let source = source
        let store = store
        let pageSize = songPageSize
        let task = Task {
            try await Self.syncTracks(
                source: source,
                store: store,
                serverID: serverID,
                pageSize: pageSize
            )
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        try await task.value
    }

    private static func syncArtists(
        source: any LibraryRemoteSource,
        store: LibraryIndexStore,
        serverID: UUID
    ) async throws {
        try Task.checkCancellation()
        let previousCount = try await store.counts(for: serverID).artists
        let indexes = try await source.artists(serverID: serverID)
        try Task.checkCancellation()

        var seen: Set<String> = []
        let artists = indexes.flatMap { index in
            index.artist.compactMap { artist -> (indexName: String, artist: ArtistID3)? in
                seen.insert(artist.id).inserted ? (index.name, artist) : nil
            }
        }
        guard previousCount == 0 || !artists.isEmpty else {
            throw LibraryIndexError.suspiciousEmptyResponse(.artists)
        }

        let generation = UUID().uuidString
        try await store.upsertArtists(artists, serverID: serverID, generation: generation)
        try Task.checkCancellation()
        try await store.complete(.artists, serverID: serverID, generation: generation)
        Logger.library.info("Library index: artists refreshed (\(artists.count, privacy: .public))")
    }

    private static func syncAlbums(
        source: any LibraryRemoteSource,
        store: LibraryIndexStore,
        serverID: UUID,
        pageSize: Int
    ) async throws {
        let previousCount = try await store.counts(for: serverID).albums
        let generation = UUID().uuidString
        var offset = 0
        var seen: Set<String> = []

        while true {
            try Task.checkCancellation()
            let page = try await source.albumsPage(offset: offset, count: pageSize, serverID: serverID)
            try Task.checkCancellation()
            guard !page.isEmpty else { break }

            let fresh = page.filter { seen.insert($0.id).inserted }
            guard !fresh.isEmpty else {
                throw LibraryIndexError.paginationDidNotAdvance(.albums, offset: offset)
            }
            try await store.upsertAlbums(fresh, serverID: serverID, generation: generation)
            offset += page.count
        }

        guard previousCount == 0 || !seen.isEmpty else {
            throw LibraryIndexError.suspiciousEmptyResponse(.albums)
        }
        try Task.checkCancellation()
        try await store.complete(.albums, serverID: serverID, generation: generation)
        Logger.library.info("Library index: albums refreshed (\(seen.count, privacy: .public))")
    }

    private static func syncTracks(
        source: any LibraryRemoteSource,
        store: LibraryIndexStore,
        serverID: UUID,
        pageSize: Int
    ) async throws {
        let previousCount = try await store.counts(for: serverID).tracks
        let generation = UUID().uuidString
        var offset = 0
        var seen: Set<String> = []

        while true {
            try Task.checkCancellation()
            let page = try await source.songsPage(offset: offset, count: pageSize, serverID: serverID)
            try Task.checkCancellation()
            guard !page.isEmpty else { break }

            let fresh = page.filter { seen.insert($0.id).inserted }
            guard !fresh.isEmpty else {
                throw LibraryIndexError.paginationDidNotAdvance(.tracks, offset: offset)
            }
            try await store.upsertTracks(
                fresh,
                serverID: serverID,
                generation: generation,
                serverOrderStart: offset
            )
            offset += page.count
        }

        guard previousCount == 0 || !seen.isEmpty else {
            throw LibraryIndexError.suspiciousEmptyResponse(.tracks)
        }
        try Task.checkCancellation()
        try await store.complete(.tracks, serverID: serverID, generation: generation)
        Logger.library.info("Library index: tracks refreshed (\(seen.count, privacy: .public))")
    }
}
