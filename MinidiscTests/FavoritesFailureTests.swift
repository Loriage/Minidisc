import Foundation
import SwiftData
import SwiftSonic
import Testing
@testable import Minidisc

private actor FavoriteRequestGate {
    private var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var request: CheckedContinuation<Void, Never>?

    func pause() async {
        entered = true
        waiter?.resume()
        waiter = nil
        await withCheckedContinuation { request = $0 }
    }

    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { waiter = $0 } }
    }

    func resume() {
        request?.resume()
        request = nil
    }
}

private actor FavoriteEditorFixture: FavoriteEditing {
    var failure: URLError?
    var songs: Set<String> = []
    var albums: Set<String> = []
    var artists: Set<String> = []
    var writes = 0
    var readGate: FavoriteRequestGate?
    var writeGate: FavoriteRequestGate?

    func fail(_ error: URLError?) { failure = error }
    func holdRead(_ gate: FavoriteRequestGate) { readGate = gate }
    func holdWrite(_ gate: FavoriteRequestGate) { writeGate = gate }

    func star(songIds: [String], albumIds: [String], artistIds: [String]) async throws {
        try await beforeWrite()
        songs.formUnion(songIds); albums.formUnion(albumIds); artists.formUnion(artistIds)
    }

    func unstar(songIds: [String], albumIds: [String], artistIds: [String]) async throws {
        try await beforeWrite()
        songs.subtract(songIds); albums.subtract(albumIds); artists.subtract(artistIds)
    }

    private func beforeWrite() async throws {
        writes += 1
        if let failure { throw failure }
        if let gate = writeGate {
            writeGate = nil
            await gate.pause()
        }
    }

    func getStarred2() async throws -> Starred2 {
        if let failure { throw failure }
        struct Payload: Encodable {
            let song: [Song]
            let album: [AlbumID3]
            let artist: [ArtistID3]
        }
        let payload = Payload(
            song: songs.map { Song(id: $0, title: $0) },
            album: albums.map { AlbumID3(id: $0, name: $0, songCount: 1, duration: 30) },
            artist: artists.map { ArtistID3(id: $0, name: $0) }
        )
        let result = try JSONDecoder().decode(Starred2.self, from: JSONEncoder().encode(payload))
        if let gate = readGate {
            readGate = nil
            await gate.pause()
        }
        return result
    }
}

@MainActor
private func favoriteServer(_ snapshot: ServerSnapshot? = nil) throws -> MockServerService {
    let server = MockServerService()
    try selectFavoriteServer(snapshot ?? ServerSnapshot(from: ServerConfig(
        displayName: "Test", baseURL: "https://example.invalid", username: "test"
    )), on: server)
    return server
}

@MainActor
private func selectFavoriteServer(_ snapshot: ServerSnapshot, on server: MockServerService) throws {
    server.state.activeServer = snapshot
    server.state.activeConnectionVersion = .init(serverID: snapshot.id, revision: 1)
    server.connection = try ServerConnection(version: server.state.activeConnectionVersion!, server: snapshot,
        credentials: ServerCredentials(password: "fixture", customHeaders: [:]))
}

@Suite @MainActor
struct FavoritesFailureTests {
    @Test func failedFirstRefreshDoesNotPresentAnEmptyFavoritesList() async throws {
        let models = try ModelContainer.minidisc(inMemory: true)
        let server = try favoriteServer()
        let editor = FavoriteEditorFixture()
        await editor.fail(URLError(.timedOut))
        let service = FavoritesService(server: server, modelContainer: models,
            offlineStore: OfflineFavoritesStore(directory: .temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            clientFactory: { _ in editor })
        await #expect(throws: URLError.self) { _ = try await service.getStarred2() }
    }

    @Test func connectionFailureKeepsTheLatestLocalIntentUntilRetry() async throws {
        let models = try ModelContainer.minidisc(inMemory: true)
        let server = try favoriteServer()
        let editor = FavoriteEditorFixture()
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = FavoritesService(server: server, modelContainer: models,
            offlineStore: OfflineFavoritesStore(directory: directory), clientFactory: { _ in editor })
        await editor.fail(URLError(.timedOut))
        try await service.star(itemType: .song, itemId: "track")
        #expect(service.isFavorite(itemType: .song, itemId: "track"))
        try await service.unstar(itemType: .song, itemId: "track")
        #expect(!service.isFavorite(itemType: .song, itemId: "track"))
        let pending = try ModelContext(models).fetch(FetchDescriptor<PendingFavoriteChange>())
        #expect(pending.count == 1 && pending.first?.isFavorite == false)
        await editor.fail(nil)
        try await service.syncFromServer()
        #expect(try ModelContext(models).fetchCount(FetchDescriptor<PendingFavoriteChange>()) == 0)
        #expect(await editor.songs.isEmpty)
    }

    @Test func authenticationFailureIsReportedWithoutLosingTheIntent() async throws {
        let models = try ModelContainer.minidisc(inMemory: true)
        let server = try favoriteServer()
        let editor = FavoriteEditorFixture()
        await editor.fail(URLError(.userAuthenticationRequired))
        let service = FavoritesService(server: server, modelContainer: models,
            offlineStore: OfflineFavoritesStore(directory: .temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            clientFactory: { _ in editor })
        await #expect(throws: URLError.self) { try await service.star(itemType: .song, itemId: "track") }
        #expect(service.isFavorite(itemType: .song, itemId: "track"))
        #expect(try ModelContext(models).fetchCount(FetchDescriptor<PendingFavoriteChange>()) == 1)
    }

    @Test func missingServerCannotReportFavoriteSuccess() async throws {
        let models = try ModelContainer.minidisc(inMemory: true)
        let service = FavoritesService(server: MockServerService(), modelContainer: models,
            offlineStore: OfflineFavoritesStore(directory: .temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        do { try await service.star(itemType: .song, itemId: "track"); Issue.record("Expected missing server") }
        catch MinidiscError.serverNotConfigured { }
        #expect(try ModelContext(models).fetchCount(FetchDescriptor<FavoriteRecord>()) == 0)
        #expect(try ModelContext(models).fetchCount(FetchDescriptor<PendingFavoriteChange>()) == 0)
    }
}

@Suite @MainActor
struct OfflineFavoriteEditingTests {
    @Test func automaticDownloadsFlushEditsBeforeReconcilingTheCatalog() async throws {
        let models = try ModelContainer.minidisc(inMemory: true)
        let server = try favoriteServer()
        server.state.hasObservedNetworkPath = true
        let serverID = try #require(server.state.activeServer?.id)
        let editor = FavoriteEditorFixture()
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OfflineFavoritesStore(directory: root.appendingPathComponent("catalog"))
        let service = FavoritesService(server: server, modelContainer: models, offlineStore: store, clientFactory: { _ in editor })
        let cache = AudioStreamCache(modelContainer: models)
        let audio = root.appendingPathComponent("song.mp3")
        try Data("ID3 audio fixture".utf8).write(to: audio)
        let cached = try await cache.store(fileAt: audio, forSongId: "song", serverId: serverID, mimeType: "audio/mpeg")
        defer { try? FileManager.default.removeItem(at: cached) }
        let suite = "FavoriteEditing.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = CacheSettings(defaults: defaults)
        let sync = OfflineFavoritesSync(store: store, settings: settings, streamSettings: StreamSettings(defaults: defaults),
            server: server, downloads: DownloadService(serverService: server, modelContainer: models, toastService: ToastService()),
            cache: cache, fetchFavorites: { try await service.refreshedFavorites(for: $0) })
        server.state.isOnline = false
        try await service.star(itemType: .song, itemId: "song")
        server.state.isOnline = true
        await sync.synchronize()
        #expect(sync.error == nil)
        #expect(await store.localURL(songID: "song", serverID: serverID) != nil)
        #expect(await editor.songs == ["song"])
        server.state.isOnline = false
        try await service.unstar(itemType: .song, itemId: "song")
        server.state.isOnline = true
        await sync.synchronize()
        #expect(sync.error == nil)
        #expect(await store.localURL(songID: "song", serverID: serverID) == nil)
        #expect(await editor.songs.isEmpty)
        #expect(try ModelContext(models).fetchCount(FetchDescriptor<PendingFavoriteChange>()) == 0)
        settings.keepFavoritesOffline = false
        server.state.isOnline = false
        try await service.star(itemType: .song, itemId: "song")
        server.state.isOnline = true
        try await service.syncFromServer()
        #expect(await editor.songs == ["song"])
        #expect(await store.localURL(songID: "song", serverID: serverID) == nil)
    }

    @Test func offlineFavoritesListReflectsEditsWithoutRemovingPlayableAudio() async throws {
        let models = try ModelContainer.minidisc(inMemory: true)
        let server = try favoriteServer()
        server.state.isOnline = false
        let serverID = try #require(server.state.activeServer?.id)
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OfflineFavoritesStore(directory: root.appendingPathComponent("catalog"))
        let track = Song(id: "song", title: "Saved", album: "Album", artist: "Artist", albumId: "album", artistId: "artist")
        let album = AlbumID3(id: "album", name: "Album", songCount: 1, duration: 30, artist: "Artist", artistId: "artist", song: [track])
        let starred = try JSONDecoder().decode(Starred2.self, from: JSONEncoder().encode(["album": [album]]))
        _ = try await store.reconcile(favorites: starred, albums: [album], serverID: serverID)
        let audio = root.appendingPathComponent("song.mp3")
        try Data("ID3 audio fixture".utf8).write(to: audio)
        try await store.store(fileAt: audio, songID: "song", serverID: serverID)
        let cache = AudioStreamCache(modelContainer: models, offlineFavorites: store)
        let downloads = DownloadService(serverService: server, modelContainer: models, toastService: ToastService())
        let reader = OfflineBrowsingReader(models: models, downloads: downloads, cache: cache, favorites: store,
            index: LibraryIndexStore(modelContainer: try ModelContainer.libraryIndex(inMemory: true)))
        let service = FavoritesService(server: server, modelContainer: models, offlineStore: store, offlineReader: reader)
        try await service.star(itemType: .song, itemId: "song")
        try await service.star(itemType: .artist, itemId: "artist")
        try await service.unstar(itemType: .album, itemId: "album")
        let snapshot = try await reader.read(serverID: serverID)
        #expect(snapshot.favorites.songs.map(\.id) == ["song"])
        #expect(snapshot.favorites.artists.map(\.id) == ["artist"])
        #expect(snapshot.favorites.albums.isEmpty)
        #expect(await store.localURL(songID: "song", serverID: serverID) != nil)
        let cached = try await service.getStarred2()
        #expect(cached.song?.map(\.id) == ["song"])
        #expect(cached.artist?.map(\.id) == ["artist"])
        #expect(cached.album?.isEmpty == true)
        try await service.star(itemType: .album, itemId: "album")
        try await service.unstar(itemType: .song, itemId: "song")
        let updated = try await reader.read(serverID: serverID)
        #expect(updated.favorites.songs.isEmpty)
        #expect(updated.favorites.albums.map(\.id) == ["album"])
    }

    @Test func offlineEditsSurviveRestartAndCoalesceForSongsAlbumsAndArtists() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try favoriteServer()
        server.state.isOnline = false
        let editor = FavoriteEditorFixture()
        let schema = Schema([FavoriteRecord.self, PendingFavoriteChange.self])
        let config = ModelConfiguration(schema: schema, url: root.appendingPathComponent("favorites.store"))
        func openModels() throws -> ModelContainer { try ModelContainer(for: schema, configurations: config) }
        func service(_ models: ModelContainer) -> FavoritesService {
            FavoritesService(server: server, modelContainer: models,
                offlineStore: OfflineFavoritesStore(directory: root.appendingPathComponent("catalog")), clientFactory: { _ in editor })
        }
        do {
            let models = try openModels()
            let favorites = service(models)
            for type in FavoriteType.allCases {
                try await favorites.star(itemType: type, itemId: "same")
                try await favorites.unstar(itemType: type, itemId: "same")
                try await favorites.star(itemType: type, itemId: "same")
                #expect(favorites.isFavorite(itemType: type, itemId: "same"))
            }
            #expect(try ModelContext(models).fetchCount(FetchDescriptor<PendingFavoriteChange>()) == 3)
            #expect(await editor.writes == 0)
        }
        let restoredModels = try openModels()
        let restored = service(restoredModels)
        #expect(try ModelContext(restoredModels).fetchCount(FetchDescriptor<PendingFavoriteChange>()) == 3)
        server.state.isOnline = true
        try await restored.syncFromServer()
        #expect(await editor.songs == ["same"])
        #expect(await editor.albums == ["same"])
        #expect(await editor.artists == ["same"])
        #expect(await editor.writes == 3)
        #expect(try ModelContext(restoredModels).fetchCount(FetchDescriptor<PendingFavoriteChange>()) == 0)
    }

    @Test func editDuringAReadCannotBeOverwrittenByTheStaleResponse() async throws {
        let models = try ModelContainer.minidisc(inMemory: true)
        let server = try favoriteServer()
        let editor = FavoriteEditorFixture()
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = FavoritesService(server: server, modelContainer: models,
            offlineStore: OfflineFavoritesStore(directory: root), clientFactory: { _ in editor })
        let gate = FavoriteRequestGate()
        await editor.holdRead(gate)
        let refresh = Task { try await service.syncFromServer() }
        await gate.waitUntilEntered()
        server.state.isOnline = false
        try await service.star(itemType: .song, itemId: "new")
        server.state.isOnline = true
        await gate.resume()
        try await refresh.value
        #expect(service.isFavorite(itemType: .song, itemId: "new"))
        #expect(await editor.songs == ["new"])
        #expect(try ModelContext(models).fetchCount(FetchDescriptor<PendingFavoriteChange>()) == 0)
    }

    @Test(arguments: [false, true])
    func newerIntentIsNotAcknowledgedByAnOlderWrite(reconnect: Bool) async throws {
        let models = try ModelContainer.minidisc(inMemory: true)
        let server = try favoriteServer()
        let editor = FavoriteEditorFixture()
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = FavoritesService(server: server, modelContainer: models,
            offlineStore: OfflineFavoritesStore(directory: root), clientFactory: { _ in editor })
        server.state.isOnline = false
        try await service.star(itemType: .song, itemId: "track")
        let gate = FavoriteRequestGate()
        await editor.holdWrite(gate)
        server.state.isOnline = true
        let refresh = Task { try await service.syncFromServer() }
        await gate.waitUntilEntered()
        server.state.isOnline = false
        try await service.unstar(itemType: .song, itemId: "track")
        server.state.isOnline = true
        var reconnected: Task<Void, Error>?
        if reconnect {
            let previous = try #require(server.connection)
            let version = ServerConnection.Version(serverID: previous.server.id, revision: previous.version.revision + 1)
            server.connection = try ServerConnection(version: version, server: previous.server, credentials: previous.credentials)
            server.state.activeConnectionVersion = version
            reconnected = Task { try await service.syncFromServer() }
        }
        await gate.resume()
        if let reconnected {
            await #expect(throws: CancellationError.self) { try await refresh.value }
            try await reconnected.value
        } else {
            try await refresh.value
        }
        #expect(!service.isFavorite(itemType: .song, itemId: "track"))
        #expect(await editor.songs.isEmpty)
        #expect(await editor.writes == 2)
        #expect(try ModelContext(models).fetchCount(FetchDescriptor<PendingFavoriteChange>()) == 0)
    }

    @Test func switchingAccountsDuringAWriteKeepsQueuesSeparate() async throws {
        let models = try ModelContainer.minidisc(inMemory: true)
        let server = try favoriteServer()
        let first = try #require(server.state.activeServer)
        let second = ServerSnapshot(from: ServerConfig(displayName: "B", baseURL: first.baseURL, username: "other"))
        let editorA = FavoriteEditorFixture()
        let editorB = FavoriteEditorFixture()
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = FavoritesService(server: server, modelContainer: models,
            offlineStore: OfflineFavoritesStore(directory: root),
            clientFactory: { $0.server.id == first.id ? editorA : editorB })
        server.state.isOnline = false
        try await service.star(itemType: .song, itemId: "same")
        let gate = FavoriteRequestGate()
        await editorA.holdWrite(gate)
        server.state.isOnline = true
        let refresh = Task { try await service.syncFromServer() }
        await gate.waitUntilEntered()
        try selectFavoriteServer(second, on: server)
        await gate.resume()
        await #expect(throws: CancellationError.self) { try await refresh.value }
        try await service.syncFromServer()
        #expect(await editorB.writes == 0)
        #expect(!service.isFavorite(itemType: .song, itemId: "same"))
        #expect(try ModelContext(models).fetchCount(FetchDescriptor<PendingFavoriteChange>()) == 1)
        try selectFavoriteServer(first, on: server)
        try await service.syncFromServer()
        #expect(service.isFavorite(itemType: .song, itemId: "same"))
        #expect(try ModelContext(models).fetchCount(FetchDescriptor<PendingFavoriteChange>()) == 0)
    }
}

@Suite @MainActor
struct FavoriteServerIsolationTests {
    @Test func pinsAndTheirLimitAreScopedToTheActiveServer() throws {
        let container = try ModelContainer.minidisc(inMemory: true)
        let state = ServerState()
        let a = ServerSnapshot(from: ServerConfig(displayName: "A", baseURL: "https://a.invalid", username: "u"))
        let b = ServerSnapshot(from: ServerConfig(displayName: "B", baseURL: "https://b.invalid", username: "u"))
        let service = PinService(modelContainer: container, serverState: state)
        state.activeServer = a
        for index in 0..<6 {
            try service.pin(itemType: .album, itemId: "\(index)", displayName: "Album", displaySubtitle: "Artist", coverArtId: nil, serverId: a.id)
        }
        state.activeServer = b
        #expect(service.currentPinnedCount() == 0)
        #expect(!service.isPinned(itemType: .album, itemId: "0"))
        try service.pin(itemType: .album, itemId: "0", displayName: "Other", displaySubtitle: "Artist", coverArtId: nil, serverId: b.id)
        service.unpin(itemType: .album, itemId: "0")
        state.activeServer = a
        #expect(service.currentPinnedCount() == 6)
        #expect(service.isPinned(itemType: .album, itemId: "0"))
    }

    @Test func legacyKeysMigrateIdempotentlyWithoutLosingMetadata() throws {
        let container = try ModelContainer.minidisc(inMemory: true)
        let serverID = UUID()
        let date = Date(timeIntervalSince1970: 123456)
        let context = ModelContext(container)
        let favorite = FavoriteRecord(itemType: .song, itemId: "same", starredDate: date, serverId: serverID)
        favorite.id = "song:same"
        let pin = PinnedItem(itemType: .album, itemId: "same", displayName: "Original", displaySubtitle: "Artist", coverArtId: "cover", serverId: serverID, sortOrder: 3)
        pin.id = "album:same"
        context.insert(favorite)
        context.insert(pin)
        try context.save()
        try ServerItemIdentity.migrate(in: container)
        try ServerItemIdentity.migrate(in: container)
        let read = ModelContext(container)
        let favorites = try read.fetch(FetchDescriptor<FavoriteRecord>())
        let pins = try read.fetch(FetchDescriptor<PinnedItem>())
        #expect(favorites.count == 1 && pins.count == 1)
        #expect(favorites.first?.id == ServerItemIdentity.key(serverID: serverID, type: "song", itemID: "same"))
        #expect(favorites.first?.starredDate == date)
        #expect(pins.first?.id == ServerItemIdentity.key(serverID: serverID, type: "album", itemID: "same"))
        #expect(pins.first?.displayName == "Original")
        #expect(pins.first?.sortOrder == 3)
        #expect(pins.first?.coverArtId == "cover")
    }
}
