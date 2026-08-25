import Foundation
import SwiftData
import SwiftSonic
import Testing
@testable import Minidisc

private enum LibrarySourceStubError: Error, Equatable {
    case unavailable
    case scheduledFailure
}

private nonisolated struct StaticLibrarySource: LibraryRemoteSource {
    let serverID: UUID
    var online = true
    var artistIndexes: [ArtistIndex] = []
    var albumPages: [Int: [AlbumID3]] = [:]
    var songPages: [Int: [Song]] = [:]
    var failingAlbumOffset: Int?
    var failingSongOffset: Int?

    func activeServerID() async throws -> UUID { serverID }
    func isOnline() async -> Bool { online }
    func search(_ query: String, serverID: UUID) async throws -> SearchResult3 {
        throw LibrarySourceStubError.unavailable
    }
    func artists(serverID: UUID) async throws -> [ArtistIndex] { artistIndexes }
    func artist(id: String, serverID: UUID) async throws -> ArtistID3 {
        guard let artist = artistIndexes.flatMap(\.artist).first(where: { $0.id == id }) else {
            throw LibrarySourceStubError.unavailable
        }
        return artist
    }
    func album(id: String, serverID: UUID) async throws -> AlbumID3 {
        guard let album = albumPages.values.flatMap({ $0 }).first(where: { $0.id == id }) else {
            throw LibrarySourceStubError.unavailable
        }
        return album
    }
    func recentlyAddedAlbums(size: Int, serverID: UUID) async throws -> [AlbumID3] {
        Array(albumPages.values.flatMap { $0 }.prefix(size))
    }
    func albumsPage(offset: Int, count: Int, serverID: UUID) async throws -> [AlbumID3] {
        if failingAlbumOffset == offset { throw LibrarySourceStubError.scheduledFailure }
        return albumPages[offset] ?? []
    }
    func songsPage(offset: Int, count: Int, serverID: UUID) async throws -> [Song] {
        if failingSongOffset == offset { throw LibrarySourceStubError.scheduledFailure }
        return songPages[offset] ?? []
    }
}

private actor CountingLibrarySource: LibraryRemoteSource {
    let serverID: UUID
    private var searchCalls = 0

    init(serverID: UUID) {
        self.serverID = serverID
    }

    func activeServerID() async throws -> UUID { serverID }
    func isOnline() async -> Bool { true }
    func search(_ query: String, serverID: UUID) async throws -> SearchResult3 {
        searchCalls += 1
        throw LibrarySourceStubError.unavailable
    }
    func artists(serverID: UUID) async throws -> [ArtistIndex] { throw LibrarySourceStubError.unavailable }
    func artist(id: String, serverID: UUID) async throws -> ArtistID3 { throw LibrarySourceStubError.unavailable }
    func album(id: String, serverID: UUID) async throws -> AlbumID3 { throw LibrarySourceStubError.unavailable }
    func recentlyAddedAlbums(size: Int, serverID: UUID) async throws -> [AlbumID3] {
        throw LibrarySourceStubError.unavailable
    }
    func albumsPage(offset: Int, count: Int, serverID: UUID) async throws -> [AlbumID3] {
        throw LibrarySourceStubError.unavailable
    }
    func songsPage(offset: Int, count: Int, serverID: UUID) async throws -> [Song] {
        throw LibrarySourceStubError.unavailable
    }

    func searchCallCount() -> Int { searchCalls }
}

private actor PreparationLibrarySource: LibraryRemoteSource {
    let serverID: UUID
    private var artistCalls = 0
    private var albumCalls = 0
    private var songCalls = 0

    init(serverID: UUID) {
        self.serverID = serverID
    }

    func activeServerID() async throws -> UUID { serverID }
    func isOnline() async -> Bool { true }
    func search(_ query: String, serverID: UUID) async throws -> SearchResult3 {
        throw LibrarySourceStubError.unavailable
    }
    func artists(serverID: UUID) async throws -> [ArtistIndex] {
        artistCalls += 1
        throw LibrarySourceStubError.scheduledFailure
    }
    func artist(id: String, serverID: UUID) async throws -> ArtistID3 {
        throw LibrarySourceStubError.unavailable
    }
    func album(id: String, serverID: UUID) async throws -> AlbumID3 {
        throw LibrarySourceStubError.unavailable
    }
    func recentlyAddedAlbums(size: Int, serverID: UUID) async throws -> [AlbumID3] {
        throw LibrarySourceStubError.unavailable
    }
    func albumsPage(offset: Int, count: Int, serverID: UUID) async throws -> [AlbumID3] {
        albumCalls += 1
        return []
    }
    func songsPage(offset: Int, count: Int, serverID: UUID) async throws -> [Song] {
        songCalls += 1
        return []
    }

    func scanCounts() -> (artists: Int, albums: Int, songs: Int) {
        (artistCalls, albumCalls, songCalls)
    }
}

@Suite("Persistent library index")
@MainActor
struct LibraryIndexTests {
    @Test("a completed generation replaces stale rows and updates payloads")
    func completedGenerationReplacesStaleRows() async throws {
        let store = try makeStore()
        let serverID = UUID()
        try await store.upsertTracks(
            [song(id: "one", title: "Old title"), song(id: "stale", title: "Stale")],
            serverID: serverID,
            generation: "first",
            serverOrderStart: 0
        )
        try await store.complete(.tracks, serverID: serverID, generation: "first")

        try await store.upsertTracks(
            [song(id: "one", title: "New title")],
            serverID: serverID,
            generation: "second",
            serverOrderStart: 0
        )
        try await store.complete(.tracks, serverID: serverID, generation: "second")

        let indexed = try await store.songs(serverID: serverID, offset: 0, count: 10)
        #expect(indexed.map(\.id) == ["one"])
        #expect(indexed.first?.title == "New title")
        #expect(try await store.counts(for: serverID).tracks == 1)
    }

    @Test("a failed refresh keeps every row from the previous completed generation")
    func failedRefreshKeepsPreviousGeneration() async throws {
        let store = try makeStore()
        let serverID = UUID()
        try await store.upsertTracks(
            [song(id: "one", title: "One"), song(id: "two", title: "Two")],
            serverID: serverID,
            generation: "stable",
            serverOrderStart: 0
        )
        try await store.complete(.tracks, serverID: serverID, generation: "stable")

        let source = StaticLibrarySource(
            serverID: serverID,
            songPages: [
                0: [song(id: "one", title: "Updated"), song(id: "three", title: "Three")]
            ],
            failingSongOffset: 2
        )
        let synchronizer = LibraryIndexSynchronizer(
            source: source,
            store: store,
            albumPageSize: 2,
            songPageSize: 2
        )

        await #expect(throws: LibrarySourceStubError.scheduledFailure) {
            try await synchronizer.refreshTracks(serverID: serverID)
        }

        let ids = Set(try await store.songs(serverID: serverID, offset: 0, count: 10).map(\.id))
        #expect(ids == Set(["one", "two", "three"]))
        #expect(try await store.completion(for: serverID).tracks)
    }

    @Test("an unexpected empty server response cannot erase a non-empty index")
    func suspiciousEmptyResponseKeepsIndex() async throws {
        let store = try makeStore()
        let serverID = UUID()
        try await store.upsertAlbums(
            [album(id: "album", name: "Album")],
            serverID: serverID,
            generation: "stable"
        )
        try await store.complete(.albums, serverID: serverID, generation: "stable")

        let source = StaticLibrarySource(serverID: serverID)
        let synchronizer = LibraryIndexSynchronizer(
            source: source,
            store: store,
            albumPageSize: 2,
            songPageSize: 2
        )

        await #expect(throws: LibraryIndexError.suspiciousEmptyResponse(.albums)) {
            try await synchronizer.refreshAlbums(serverID: serverID)
        }
        #expect(try await store.albums(serverID: serverID).map(\.id) == ["album"])
    }

    @Test("a server-side page cap cannot truncate the track index")
    func shortPagesContinueUntilEmpty() async throws {
        let store = try makeStore()
        let serverID = UUID()
        let source = StaticLibrarySource(
            serverID: serverID,
            songPages: [
                0: [song(id: "one", title: "One")],
                1: [song(id: "two", title: "Two")]
            ]
        )
        let synchronizer = LibraryIndexSynchronizer(
            source: source,
            store: store,
            albumPageSize: 2,
            songPageSize: 2
        )

        try await synchronizer.refreshTracks(serverID: serverID)

        #expect(try await store.songs(serverID: serverID, offset: 0, count: 10).map(\.id) == ["one", "two"])
        #expect(try await store.completion(for: serverID).tracks)
    }

    @Test("one failed entity scan does not block the other index generations")
    func preparationKeepsEntityScansIndependent() async throws {
        let store = try makeStore()
        let serverID = UUID()
        let source = PreparationLibrarySource(serverID: serverID)
        let synchronizer = LibraryIndexSynchronizer(source: source, store: store)

        await #expect(throws: LibrarySourceStubError.scheduledFailure) {
            try await synchronizer.prepare(serverID: serverID)
        }

        let completion = try await store.completion(for: serverID)
        #expect(!completion.artists)
        #expect(completion.albums)
        #expect(completion.tracks)
        let calls = await source.scanCounts()
        #expect(calls.artists == 1)
        #expect(calls.albums == 1)
        #expect(calls.songs == 1)
    }

    @Test("completed local search avoids the server and preserves ReplayGain metadata")
    func localSearchAvoidsServerAndPreservesPayload() async throws {
        let store = try makeStore()
        let serverID = UUID()
        let replayGain = ReplayGain(
            trackGain: -9.57,
            albumGain: -9.57,
            trackPeak: 0.994904,
            albumPeak: 0.994904
        )
        let indexedSong = song(id: "song", title: "Aimé", replayGain: replayGain)
        let indexedAlbum = album(id: "album", name: "Été avec toi")
        let indexedArtist = ArtistID3(id: "artist", name: "Adèle Castillon", albumCount: 1)

        try await store.upsertTracks(
            [indexedSong],
            serverID: serverID,
            generation: "complete",
            serverOrderStart: 0
        )
        try await store.upsertAlbums(
            [indexedAlbum],
            serverID: serverID,
            generation: "complete"
        )
        try await store.upsertArtists(
            [("A", indexedArtist)],
            serverID: serverID,
            generation: "complete"
        )
        try await store.complete(.tracks, serverID: serverID, generation: "complete")
        try await store.complete(.albums, serverID: serverID, generation: "complete")
        try await store.complete(.artists, serverID: serverID, generation: "complete")

        let source = CountingLibrarySource(serverID: serverID)
        let synchronizer = LibraryIndexSynchronizer(source: source, store: store)
        let catalog = LibraryCatalog(source: source, store: store, synchronizer: synchronizer)
        let result = try await catalog.search("aime")

        #expect(result.song?.map(\.id) == ["song"])
        #expect(result.song?.first?.replayGain == replayGain)
        #expect(await source.searchCallCount() == 0)
    }

    @Test("a completed index still asks the server after a local search miss")
    func localSearchMissCanDiscoverNewServerContent() async throws {
        let store = try makeStore()
        let serverID = UUID()
        try await store.complete(.tracks, serverID: serverID, generation: "empty")
        try await store.complete(.albums, serverID: serverID, generation: "empty")
        try await store.complete(.artists, serverID: serverID, generation: "empty")
        let source = CountingLibrarySource(serverID: serverID)
        let synchronizer = LibraryIndexSynchronizer(source: source, store: store)
        let catalog = LibraryCatalog(source: source, store: store, synchronizer: synchronizer)

        await #expect(throws: LibrarySourceStubError.unavailable) {
            try await catalog.search("new track")
        }

        #expect(await source.searchCallCount() == 1)
    }

    @Test("removing a server purges only that server's index")
    func removeServerIsScoped() async throws {
        let store = try makeStore()
        let removedID = UUID()
        let retainedID = UUID()
        try await store.upsertAlbums(
            [album(id: "shared-id", name: "Removed")],
            serverID: removedID,
            generation: "one"
        )
        try await store.upsertAlbums(
            [album(id: "shared-id", name: "Retained")],
            serverID: retainedID,
            generation: "two"
        )

        try await store.removeServer(removedID)

        #expect(try await store.albums(serverID: removedID).isEmpty)
        #expect(try await store.albums(serverID: retainedID).map(\.name) == ["Retained"])
    }

    @Test("resetting a changed server allows the same configuration ID to be indexed again")
    func resetServerAllowsReindexing() async throws {
        let store = try makeStore()
        let serverID = UUID()
        try await store.upsertAlbums(
            [album(id: "old", name: "Old server")],
            serverID: serverID,
            generation: "old"
        )
        try await store.complete(.albums, serverID: serverID, generation: "old")

        try await store.resetServer(serverID)
        try await store.upsertAlbums(
            [album(id: "new", name: "New server")],
            serverID: serverID,
            generation: "new"
        )

        #expect(try await store.albums(serverID: serverID).map(\.id) == ["new"])
        #expect(!((try await store.completion(for: serverID)).albums))
    }

    private func makeStore() throws -> LibraryIndexStore {
        LibraryIndexStore(modelContainer: try ModelContainer.libraryIndex(inMemory: true))
    }

    private func song(
        id: String,
        title: String,
        replayGain: ReplayGain? = nil
    ) -> Song {
        Song(
            id: id,
            title: title,
            album: "Été avec toi",
            artist: "Adèle Castillon",
            track: 1,
            year: 2026,
            albumId: "album",
            artistId: "artist",
            replayGain: replayGain
        )
    }

    private func album(id: String, name: String) -> AlbumID3 {
        AlbumID3(
            id: id,
            name: name,
            songCount: 1,
            duration: 200,
            artist: "Adèle Castillon",
            artistId: "artist",
            year: 2026
        )
    }
}
