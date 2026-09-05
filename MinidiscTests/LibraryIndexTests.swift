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
    var playlistSummaries: [Playlist] = []
    var playlistDetails: [String: PlaylistWithSongs] = [:]
    var playlistFailure: SwiftSonicError?
    var recentAlbumsFailure: SwiftSonicError?
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
        if let recentAlbumsFailure { throw recentAlbumsFailure }
        return Array(albumPages.values.flatMap { $0 }.prefix(size))
    }
    func albumsPage(offset: Int, count: Int, serverID: UUID) async throws -> [AlbumID3] {
        if failingAlbumOffset == offset { throw LibrarySourceStubError.scheduledFailure }
        return albumPages[offset] ?? []
    }
    func songsPage(offset: Int, count: Int, serverID: UUID) async throws -> [Song] {
        if failingSongOffset == offset { throw LibrarySourceStubError.scheduledFailure }
        return songPages[offset] ?? []
    }
    func playlists(serverID: UUID) async throws -> [Playlist] { playlistSummaries }
    func playlist(id: String, serverID: UUID) async throws -> PlaylistWithSongs {
        if let playlistFailure { throw playlistFailure }
        guard let playlist = playlistDetails[id] else { throw LibrarySourceStubError.unavailable }
        return playlist
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
    func playlists(serverID: UUID) async throws -> [Playlist] { [] }
    func playlist(id: String, serverID: UUID) async throws -> PlaylistWithSongs {
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
    func playlists(serverID: UUID) async throws -> [Playlist] { [] }
    func playlist(id: String, serverID: UUID) async throws -> PlaylistWithSongs {
        throw LibrarySourceStubError.unavailable
    }

    func scanCounts() -> (artists: Int, albums: Int, songs: Int) {
        (artistCalls, albumCalls, songCalls)
    }
}

private actor FreshnessLibrarySource: LibraryRemoteSource {
    let serverID: UUID
    let remoteScanStatus: LibraryRemoteScanStatus?
    let trackPageDelay: Duration?
    private var artistCalls = 0
    private var albumCalls = 0
    private var songCalls = 0

    init(
        serverID: UUID,
        remoteScanStatus: LibraryRemoteScanStatus? = nil,
        trackPageDelay: Duration? = nil
    ) {
        self.serverID = serverID
        self.remoteScanStatus = remoteScanStatus
        self.trackPageDelay = trackPageDelay
    }

    func activeServerID() async throws -> UUID { serverID }
    func isOnline() async -> Bool { true }
    func scanStatus(serverID: UUID) async throws -> LibraryRemoteScanStatus? { remoteScanStatus }
    func search(_ query: String, serverID: UUID) async throws -> SearchResult3 {
        throw LibrarySourceStubError.unavailable
    }
    func artists(serverID: UUID) async throws -> [ArtistIndex] {
        artistCalls += 1
        return []
    }
    func artist(id: String, serverID: UUID) async throws -> ArtistID3 {
        throw LibrarySourceStubError.unavailable
    }
    func album(id: String, serverID: UUID) async throws -> AlbumID3 {
        throw LibrarySourceStubError.unavailable
    }
    func recentlyAddedAlbums(size: Int, serverID: UUID) async throws -> [AlbumID3] { [] }
    func albumsPage(offset: Int, count: Int, serverID: UUID) async throws -> [AlbumID3] {
        albumCalls += 1
        return []
    }
    func songsPage(offset: Int, count: Int, serverID: UUID) async throws -> [Song] {
        songCalls += 1
        if let trackPageDelay { try await Task.sleep(for: trackPageDelay) }
        return []
    }
    func playlists(serverID: UUID) async throws -> [Playlist] { [] }
    func playlist(id: String, serverID: UUID) async throws -> PlaylistWithSongs {
        throw LibrarySourceStubError.unavailable
    }

    func scanCounts() -> (artists: Int, albums: Int, songs: Int) {
        (artistCalls, albumCalls, songCalls)
    }
}

@Suite("Persistent library index")
@MainActor
struct LibraryIndexTests {
    @Test("recent additions use the current server page while the completed index still reflects an older scan")
    func recentAdditionsRefreshCompletedIndex() async throws {
        let store = try makeStore()
        let serverID = UUID()
        try await store.upsertAlbums([album(id: "old", name: "Old")], serverID: serverID, generation: "previous")
        try await store.complete(.albums, serverID: serverID, generation: "previous")
        let source = StaticLibrarySource(serverID: serverID, albumPages: [0: [album(id: "new", name: "New")]])
        let catalog = LibraryCatalog(source: source, store: store,
                                     synchronizer: LibraryIndexSynchronizer(source: source, store: store))

        #expect(try await catalog.recentlyAddedAlbums(size: 12).map(\.id) == ["new"])
        #expect(try await store.albums(serverID: serverID).map(\.id) == ["old"],
                "A recent page must not replace the full library index.")
    }

    @Test("recent additions retain the completed index offline and during transient failures", arguments: [false, true])
    func recentAdditionsKeepOfflineFallback(online: Bool) async throws {
        let store = try makeStore()
        let serverID = UUID()
        try await store.upsertAlbums([album(id: "saved", name: "Saved")], serverID: serverID, generation: "previous")
        try await store.complete(.albums, serverID: serverID, generation: "previous")
        let source = StaticLibrarySource(serverID: serverID, online: online,
                                         recentAlbumsFailure: .network(URLError(.timedOut)))
        let catalog = LibraryCatalog(source: source, store: store,
                                     synchronizer: LibraryIndexSynchronizer(source: source, store: store))

        #expect(try await catalog.recentlyAddedAlbums(size: 12).map(\.id) == ["saved"])
    }

    @Test("the V1 library store migrates to V3 without losing indexed media")
    func v1StoreMigratesToV3() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "MinidiscLibraryMigration-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let storeURL = directory.appending(path: "library.store")
        let album = album(id: "preserved", name: "Preserved Album")
        let payload = try JSONEncoder().encode(album)
        let serverID = UUID()

        do {
            let schema = Schema(versionedSchema: LibraryIndexSchemaV1.self)
            let configuration = ModelConfiguration(
                "migration-test",
                schema: schema,
                url: storeURL,
                cloudKitDatabase: .none
            )
            let container = try ModelContainer(for: schema, configurations: configuration)
            let context = ModelContext(container)
            context.insert(
                IndexedAlbum(
                    recordKey: "\(serverID.uuidString)|preserved",
                    serverId: serverID,
                    itemId: album.id,
                    name: album.name,
                    artistName: album.artist,
                    artistId: album.artistId,
                    searchText: LibraryIndexText.searchText(album.name, album.artist),
                    sortName: LibraryIndexText.normalized(album.name),
                    createdAt: album.created,
                    generation: "v1",
                    payload: payload
                )
            )
            try context.save()
        }

        let schema = Schema(versionedSchema: LibraryIndexSchemaV3.self)
        let configuration = ModelConfiguration(
            "migration-test",
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(
            for: schema,
            migrationPlan: LibraryIndexMigrationPlan.self,
            configurations: configuration
        )
        let context = ModelContext(container)

        #expect(try context.fetch(FetchDescriptor<IndexedAlbum>()).map(\.itemId) == [album.id])
        #expect(try context.fetchCount(FetchDescriptor<IndexedPlaylist>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<IndexedAlbumRecommendation>()) == 0)
    }

    @Test("album recommendations persist positive and empty results")
    func recommendationCachePersistsPositiveAndEmptyResults() async throws {
        let store = try makeStore()
        let serverID = UUID()
        let recommendation = album(id: "recommended", name: "Recommended")

        try await store.cacheAlbumRecommendations(
            [recommendation],
            sourceAlbumID: "source-with-result",
            serverID: serverID,
            requestedLimit: 20
        )
        try await store.cacheAlbumRecommendations(
            [],
            sourceAlbumID: "source-without-result",
            serverID: serverID,
            requestedLimit: 20
        )

        let positive = try #require(try await store.albumRecommendations(
            sourceAlbumID: "source-with-result",
            serverID: serverID
        ))
        let empty = try #require(try await store.albumRecommendations(
            sourceAlbumID: "source-without-result",
            serverID: serverID
        ))

        #expect(positive.albums == [recommendation])
        #expect(positive.requestedLimit == 20)
        #expect(empty.albums.isEmpty)
        #expect(try await store.storageUsage().recommendationAlbums == 2)
    }

    @Test("recommendation resume markers require both freshness and requested depth")
    func recommendationResumeMarkersAreStrict() async throws {
        let store = try makeStore()
        let serverID = UUID()
        let now = Date.now

        try await store.cacheAlbumRecommendations(
            [],
            sourceAlbumID: "fresh-and-deep",
            serverID: serverID,
            requestedLimit: 20,
            refreshedAt: now
        )
        try await store.cacheAlbumRecommendations(
            [],
            sourceAlbumID: "fresh-but-shallow",
            serverID: serverID,
            requestedLimit: 10,
            refreshedAt: now
        )
        try await store.cacheAlbumRecommendations(
            [],
            sourceAlbumID: "deep-but-stale",
            serverID: serverID,
            requestedLimit: 20,
            refreshedAt: now.addingTimeInterval(-8 * 24 * 60 * 60)
        )

        let resumable = try await store.freshRecommendationAlbumIDs(
            serverID: serverID,
            refreshedAfter: now.addingTimeInterval(-7 * 24 * 60 * 60),
            minimumRequestedLimit: 20
        )
        #expect(resumable == ["fresh-and-deep"])
    }

    @Test("deleting the index removes metadata and recommendations together")
    func eraseAllRemovesCompleteIndex() async throws {
        let store = try makeStore()
        let serverID = UUID()
        try await store.upsertAlbums(
            [album(id: "album", name: "Album")],
            serverID: serverID,
            generation: "generation"
        )
        try await store.cacheAlbumRecommendations(
            [],
            sourceAlbumID: "album",
            serverID: serverID,
            requestedLimit: 20
        )

        try await store.eraseAll()

        let usage = try await store.storageUsage()
        #expect(usage.albums == 0)
        #expect(usage.recommendationAlbums == 0)
        #expect(try await store.albums(serverID: serverID).isEmpty)
    }

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
        #expect(try await store.status(for: serverID).tracks)
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
        #expect(try await store.status(for: serverID).tracks)
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

        let completion = try await store.status(for: serverID)
        #expect(!completion.artists)
        #expect(completion.albums)
        #expect(completion.tracks)
        #expect(completion.playlists)
        let calls = await source.scanCounts()
        #expect(calls.artists == 1)
        #expect(calls.albums == 1)
        #expect(calls.songs == 1)
    }

    @Test("automatic preparation waits for an allowed network path")
    func automaticPreparationCanBeDeferred() async throws {
        let store = try makeStore()
        let serverID = UUID()
        let source = FreshnessLibrarySource(serverID: serverID)
        let synchronizer = LibraryIndexSynchronizer(source: source, store: store)
        let catalog = LibraryCatalog(source: source, store: store, synchronizer: synchronizer)

        try await catalog.prepare(automaticRefreshAllowed: false)

        #expect(await source.scanCounts() == (artists: 0, albums: 0, songs: 0))
        #expect(!(try await store.status(for: serverID)).isComplete)
    }

    @Test("a newer completed server scan refreshes every index once")
    func serverScanWatermarkRefreshesIndexOnce() async throws {
        let store = try makeStore()
        let serverID = UUID()
        let previousSync = Date.now.addingTimeInterval(-3_600)
        let remoteScan = Date.now.addingTimeInterval(3_600)
        try await markComplete(store: store, serverID: serverID, at: previousSync)
        let source = FreshnessLibrarySource(
            serverID: serverID,
            remoteScanStatus: LibraryRemoteScanStatus(
                isScanning: false,
                lastCompletedAt: remoteScan
            )
        )
        let synchronizer = LibraryIndexSynchronizer(source: source, store: store)
        let catalog = LibraryCatalog(source: source, store: store, synchronizer: synchronizer)

        try await catalog.prepare()
        #expect(await source.scanCounts() == (artists: 1, albums: 1, songs: 1))
        let refreshedAt = try #require(try await store.status(for: serverID).fullySyncedAt)
        #expect(refreshedAt >= remoteScan)

        try await catalog.prepare()
        #expect(await source.scanCounts() == (artists: 1, albums: 1, songs: 1))
    }

    @Test("servers without scan metadata use a conservative weekly refresh")
    func missingScanMetadataUsesWeeklyFallback() async throws {
        let store = try makeStore()
        let serverID = UUID()
        let previousSync = Date.now.addingTimeInterval(-8 * 24 * 60 * 60)
        try await markComplete(store: store, serverID: serverID, at: previousSync)
        let source = FreshnessLibrarySource(serverID: serverID)
        let synchronizer = LibraryIndexSynchronizer(source: source, store: store)
        let catalog = LibraryCatalog(source: source, store: store, synchronizer: synchronizer)

        try await catalog.prepare()

        #expect(await source.scanCounts() == (artists: 1, albums: 1, songs: 1))
    }

    @Test("cancelling the owner stops the physical index scan")
    func cancellationStopsPhysicalScan() async throws {
        let store = try makeStore()
        let serverID = UUID()
        let source = FreshnessLibrarySource(
            serverID: serverID,
            trackPageDelay: .seconds(60)
        )
        let synchronizer = LibraryIndexSynchronizer(source: source, store: store)
        let refresh = Task {
            try await synchronizer.refreshTracks(serverID: serverID)
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while await source.scanCounts().songs == 0, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let scanStarted = await source.scanCounts().songs == 1
        refresh.cancel()
        try #require(scanStarted)

        await #expect(throws: CancellationError.self) {
            try await refresh.value
        }
        #expect(!(try await store.status(for: serverID)).tracks)
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
        try await store.complete(.playlists, serverID: serverID, generation: "empty")
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
        #expect(!((try await store.status(for: serverID)).albums))
    }

    @Test("playlist summaries and opened details remain available offline")
    func playlistIndexSurvivesOffline() async throws {
        let store = try makeStore()
        let serverID = UUID()
        let summary = playlist(id: "walk", name: "Dog walk", songCount: 1)
        let secondSummary = playlist(id: "morning", name: "After walk", songCount: 2)
        let detail = PlaylistWithSongs(
            id: summary.id,
            name: summary.name,
            songCount: summary.songCount,
            duration: summary.duration,
            changed: summary.changed,
            entry: [song(id: "track", title: "Outside")]
        )
        let onlineSource = StaticLibrarySource(
            serverID: serverID,
            playlistSummaries: [summary, secondSummary],
            playlistDetails: [summary.id: detail]
        )
        let onlineSynchronizer = LibraryIndexSynchronizer(source: onlineSource, store: store)
        let onlineCatalog = LibraryCatalog(
            source: onlineSource,
            store: store,
            synchronizer: onlineSynchronizer
        )

        #expect(try await onlineCatalog.refreshPlaylists().map(\.id) == [summary.id, secondSummary.id])
        #expect(try await onlineCatalog.playlist(id: summary.id).entry?.map(\.id) == ["track"])

        let offlineSource = StaticLibrarySource(serverID: serverID, online: false)
        let offlineCatalog = LibraryCatalog(
            source: offlineSource,
            store: store,
            synchronizer: LibraryIndexSynchronizer(source: offlineSource, store: store)
        )
        #expect(try await offlineCatalog.playlists().map(\.id) == [summary.id, secondSummary.id])
        #expect(try await offlineCatalog.playlist(id: summary.id).entry?.map(\.id) == ["track"])
    }

    @Test("an online playlist read refreshes a complete index and accepts an empty server list")
    func onlinePlaylistReadCanClearIndex() async throws {
        let store = try makeStore()
        let serverID = UUID()
        let populatedSource = StaticLibrarySource(
            serverID: serverID,
            playlistSummaries: [playlist(id: "old", name: "Old", songCount: 1)]
        )
        try await LibraryIndexSynchronizer(source: populatedSource, store: store)
            .refreshPlaylists(serverID: serverID)
        #expect(try await store.counts(for: serverID).playlists == 1)

        let emptySource = StaticLibrarySource(serverID: serverID)
        let catalog = LibraryCatalog(
            source: emptySource,
            store: store,
            synchronizer: LibraryIndexSynchronizer(source: emptySource, store: store)
        )

        #expect(try await catalog.playlists().isEmpty)
        #expect(try await store.counts(for: serverID).playlists == 0)
    }

    @Test("stale fallback accepts transient failures but exposes auth and configuration errors")
    func staleFallbackClassificationIsNarrow() {
        #expect(LibraryCatalog.canServeStaleData(after: URLError(.networkConnectionLost)))
        #expect(LibraryCatalog.canServeStaleData(after: SwiftSonicError.httpError(
            statusCode: 503,
            endpoint: "getPlaylists",
            serverHost: "music.example.com"
        )))
        #expect(!LibraryCatalog.canServeStaleData(after: SwiftSonicError.httpError(
            statusCode: 401,
            endpoint: "getPlaylists",
            serverHost: "music.example.com"
        )))
        #expect(!LibraryCatalog.canServeStaleData(after: SwiftSonicError.invalidConfiguration("bad URL")))
    }

    @Test("explicit playlist refresh bypasses current cache and evicts confirmed removal")
    func refreshDetectsRemovedPlaylist() async throws {
        let serverID = UUID()
        let store = try makeStore()
        try await store.cachePlaylistDetail(PlaylistWithSongs(id: "gone", name: "Gone", songCount: 1, duration: 10), serverID: serverID)
        let source = StaticLibrarySource(serverID: serverID, playlistFailure: try await playlistServerError())
        let catalog = LibraryCatalog(source: source, store: store, synchronizer: LibraryIndexSynchronizer(source: source, store: store))
        #expect(await catalog.cachedPlaylist(id: "gone") != nil)
        await #expect(throws: SwiftSonicError.self) { try await catalog.refreshPlaylist(id: "gone") }
        #expect(await catalog.cachedPlaylist(id: "gone") == nil)
    }

    @Test("a proxy failure preserves cached playlist metadata")
    func refreshFailureKeepsPlaylistCache() async throws {
        let serverID = UUID()
        let store = try makeStore()
        try await store.cachePlaylistDetail(PlaylistWithSongs(id: "kept", name: "Kept", songCount: 1, duration: 10), serverID: serverID)
        let source = StaticLibrarySource(serverID: serverID, playlistFailure: .httpError(
            statusCode: 404, endpoint: "getPlaylist", serverHost: "server.invalid"
        ))
        let catalog = LibraryCatalog(source: source, store: store, synchronizer: LibraryIndexSynchronizer(source: source, store: store))
        await #expect(throws: SwiftSonicError.self) { try await catalog.refreshPlaylist(id: "kept") }
        #expect(await catalog.cachedPlaylist(id: "kept") != nil)
    }

    private func makeStore() throws -> LibraryIndexStore {
        LibraryIndexStore(modelContainer: try ModelContainer.libraryIndex(inMemory: true))
    }

    private func markComplete(
        store: LibraryIndexStore,
        serverID: UUID,
        at date: Date
    ) async throws {
        try await store.complete(.artists, serverID: serverID, generation: "artists", syncedAt: date)
        try await store.complete(.albums, serverID: serverID, generation: "albums", syncedAt: date)
        try await store.complete(.tracks, serverID: serverID, generation: "tracks", syncedAt: date)
        try await store.complete(.playlists, serverID: serverID, generation: "playlists", syncedAt: date)
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

    private func playlist(id: String, name: String, songCount: Int) -> Playlist {
        Playlist(
            id: id,
            name: name,
            songCount: songCount,
            duration: songCount * 200,
            changed: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}
