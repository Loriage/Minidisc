import Foundation
import SwiftData
import SwiftSonic
import Testing
@testable import Minidisc

@Suite("Offline favorites")
@MainActor
struct OfflineFavoritesTests {
    private func favorites(songs: [Song] = [], albums: [AlbumID3] = []) throws -> Starred2 {
        struct Payload: Encodable { let song: [Song]; let album: [AlbumID3] }
        return try JSONDecoder().decode(Starred2.self, from: JSONEncoder().encode(Payload(song: songs, album: albums)))
    }

    private func folder() throws -> URL {
        let url = URL.temporaryDirectory.appendingPathComponent("favorites-test-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func audio(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("\(UUID()).mp3")
        try Data("ID3 offline audio fixture".utf8).write(to: url)
        return url
    }

    private func server() throws -> MockServerService {
        let server = MockServerService()
        let snapshot = ServerSnapshot(from: ServerConfig(displayName: "Fixture", baseURL: "https://example.invalid", username: "alice"))
        server.state.activeServer = snapshot
        server.state.activeConnectionVersion = .init(serverID: snapshot.id, revision: 1)
        server.state.hasObservedNetworkPath = true
        server.connection = try ServerConnection(version: server.state.activeConnectionVersion!, server: snapshot,
                                                 credentials: ServerCredentials(password: "fixture", customHeaders: [:]))
        return server
    }

    @Test func enabledByDefaultAndPreferenceSurvivesRelaunch() throws {
        let name = "OfflineFavoritesTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = CacheSettings(defaults: defaults)
        #expect(settings.keepFavoritesOffline)
        settings.keepFavoritesOffline = false
        #expect(!CacheSettings(defaults: defaults).keepFavoritesOffline)
    }

    @Test func albumAndSongOverlapRemainsUntilLastFavoriteIsRemoved() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OfflineFavoritesStore(directory: root.appendingPathComponent("store"))
        let id = UUID()
        let song = Song(id: "../same/song", title: "Shared")
        let album = AlbumID3(id: "album", name: "Album", songCount: 1, duration: 30, song: [song])
        let songs = try await store.reconcile(favorites: favorites(songs: [song], albums: [album]), albums: [album], serverID: id)
        #expect(songs.count == 1)
        let manual = try audio(in: root)
        try await store.store(fileAt: manual, songID: song.id, serverID: id)
        let local = try #require(await store.localURL(songID: song.id, serverID: id))
        #expect(local.pathExtension == "mp3")
        #expect(!local.lastPathComponent.contains(".."))

        _ = try await store.reconcile(favorites: favorites(albums: [album]), albums: [album], serverID: id)
        #expect(await store.localURL(songID: song.id, serverID: id) != nil)
        _ = try await store.reconcile(favorites: favorites(), albums: [], serverID: id)
        #expect(await store.localURL(songID: song.id, serverID: id) == nil)
        #expect(FileManager.default.fileExists(atPath: manual.path))
    }

    @Test func survivesRestartAndManualDeletionWithoutAppearingInDownloads() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("store")
        let store = OfflineFavoritesStore(directory: directory)
        let server = try server()
        let id = try #require(server.connection?.version.serverID)
        let song = Song(id: "song", title: "Saved")
        let album = AlbumID3(id: "album", name: "Album", songCount: 1, duration: 30, song: [song])
        _ = try await store.reconcile(favorites: favorites(songs: [song], albums: [album]), albums: [album], serverID: id)
        let manual = try audio(in: root)
        try await store.store(fileAt: manual, songID: song.id, serverID: id)
        try FileManager.default.removeItem(at: manual)
        let restored = OfflineFavoritesStore(directory: directory)
        let url = try #require(await restored.localURL(songID: song.id, serverID: id))
        #expect(try Data(contentsOf: url) == Data("ID3 offline audio fixture".utf8))
        #expect(await restored.localURL(songID: song.id, serverID: UUID()) == nil)
        #expect(await restored.localAlbumData(albumID: album.id, serverID: id)?.songs.map(\.id) == [song.id])

        let models = try ModelContainer.minidisc(inMemory: true)
        let cache = AudioStreamCache(modelContainer: models, maxBytes: 1, offlineFavorites: restored)
        let download = DownloadService(serverService: server, modelContainer: models, toastService: ToastService())
        let resolver = MediaResolver(downloadService: download, audioStreamCache: cache,
                                     serverService: server, serverState: server.state, streamSettings: StreamSettings())
        server.state.isOnline = false
        await cache.clearAll()
        await cache.clearAllForServer(id)
        #expect(await cache.cachedURL(forSongId: song.id, serverId: id) == url)
        #expect(await cache.trackCount == 0)
        #expect(await download.downloadedSongIds(serverId: id).isEmpty)
        #expect(await resolver.localSource(songId: song.id, serverId: id) != nil)
        let index = LibraryIndexStore(modelContainer: try ModelContainer.libraryIndex(inMemory: true))
        let source = SwiftSonicLibrarySource(serverService: server)
        let catalog = LibraryCatalog(source: source, store: index, synchronizer: LibraryIndexSynchronizer(source: source, store: index))
        let library = LibraryService(serverService: server, modelContainer: models, downloadService: download,
                                     statsService: StatsService(modelContainer: models), catalog: catalog, indexStore: index,
                                     offlineFavorites: restored)
        #expect(try await library.getStarred2().song?.first?.title == "Saved")
        #expect(try await library.album(id: album.id).song?.first?.title == "Saved")
        let vm = AlbumDetailViewModel(albumId: album.id, libraryService: library, downloadService: download,
                                      toastService: ToastService(), serverState: server.state, offlineFavorites: restored)
        await vm.load()
        #expect(vm.isOffline)
        #expect(vm.error == nil)
        #expect(vm.songs.map(\.id) == [song.id])
        #expect(vm.songs.allSatisfy { !$0.isDownloaded })
        try await restored.clearAudio()
        #expect(await resolver.localSource(songId: song.id, serverId: id) == nil)
        #expect(try await restored.snapshot(serverID: id).favorites?.song?.first?.title == "Saved")
    }

    @Test func syncReusesCacheAndDisablingPreservesManualFiles() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OfflineFavoritesStore(directory: root.appendingPathComponent("store"))
        let models = try ModelContainer.minidisc(inMemory: true)
        let server = try server()
        let id = try #require(server.connection?.version.serverID)
        let song = Song(id: "song", title: "Saved")
        let starred = try favorites(songs: [song])
        let cache = AudioStreamCache(modelContainer: models)
        let cached = try await cache.store(fileAt: audio(in: root), forSongId: song.id, serverId: id, mimeType: "audio/mpeg")
        defer { try? FileManager.default.removeItem(at: cached) }
        let settings = CacheSettings(defaults: UserDefaults(suiteName: "OfflineFavorites.\(UUID())")!)
        let downloads = DownloadService(serverService: server, modelContainer: models, toastService: ToastService())
        let sync = OfflineFavoritesSync(store: store, settings: settings, streamSettings: StreamSettings(),
                                       server: server, downloads: downloads, cache: cache,
                                       fetchFavorites: { _ in starred })
        await sync.synchronize()
        #expect(sync.error == nil)
        #expect(sync.completed == 1)
        #expect(await store.localURL(songID: song.id, serverID: id) != nil)
        #expect(await downloads.downloadedSongIds(serverId: id).isEmpty)
        settings.keepFavoritesOffline = false
        await sync.synchronize()
        #expect(try await store.usage().count == 0)
        #expect(FileManager.default.fileExists(atPath: cached.path))
    }

    @Test func unknownAndMeteredConnectionsDoNotStartAutomaticTransfers() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let models = try ModelContainer.minidisc(inMemory: true)
        let server = try server()
        let settings = CacheSettings(defaults: UserDefaults(suiteName: "OfflineFavorites.\(UUID())")!)
        let sync = OfflineFavoritesSync(store: OfflineFavoritesStore(directory: root), settings: settings,
                                       streamSettings: StreamSettings(), server: server,
                                       downloads: DownloadService(serverService: server, modelContainer: models, toastService: ToastService()),
                                       cache: AudioStreamCache(modelContainer: models),
                                       fetchFavorites: { _ in Issue.record("Must not contact the server"); throw CancellationError() })
        server.state.hasObservedNetworkPath = false
        await sync.synchronize()
        #expect(sync.waitingForWiFi)
        server.state.hasObservedNetworkPath = true
        server.state.networkPathEvent = .init(generation: 1, descriptor: .init(isOnline: true, isExpensive: true,
            isConstrained: false, supportsDNS: true, supportsIPv4: true, supportsIPv6: true, interfaces: [.cellular], gateways: []))
        await sync.synchronize()
        #expect(sync.waitingForWiFi)
        settings.cacheOverCellular = true
        #expect(!sync.waitingForWiFi)
    }

    @Test func incompleteAlbumRefreshDoesNotRemoveExistingFiles() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let models = try ModelContainer.minidisc(inMemory: true)
        let server = try server()
        let id = try #require(server.connection?.version.serverID)
        let store = OfflineFavoritesStore(directory: root.appendingPathComponent("store"))
        let song = Song(id: "saved", title: "Saved")
        _ = try await store.reconcile(favorites: favorites(songs: [song]), albums: [], serverID: id)
        try await store.store(fileAt: audio(in: root), songID: song.id, serverID: id)
        let starred = try favorites(albums: [AlbumID3(id: "unreachable", name: "Album", songCount: 1, duration: 30)])
        let sync = OfflineFavoritesSync(store: store, settings: CacheSettings(defaults: UserDefaults(suiteName: "OfflineFavorites.\(UUID())")!),
            streamSettings: StreamSettings(), server: server,
            downloads: DownloadService(serverService: server, modelContainer: models, toastService: ToastService()),
            cache: AudioStreamCache(modelContainer: models), fetchFavorites: { _ in starred },
            fetchAlbum: { _, _ in throw URLError(.timedOut) })
        await sync.synchronize()
        #expect(sync.error != nil)
        #expect(await store.localURL(songID: song.id, serverID: id) != nil)
    }
    @Test(arguments: ["server", "setting", "offline"])
    func settingsAndServerChangesCancelStaleSynchronization(change: String) async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let models = try ModelContainer.minidisc(inMemory: true)
        let server = try server()
        let id = try #require(server.connection?.version.serverID)
        let store = OfflineFavoritesStore(directory: root)
        let settings = CacheSettings(defaults: UserDefaults(suiteName: "OfflineFavorites.\(UUID())")!)
        let starred = try favorites(songs: [Song(id: "new", title: "New")])
        let sync = OfflineFavoritesSync(store: store, settings: settings, streamSettings: StreamSettings(), server: server,
            downloads: DownloadService(serverService: server, modelContainer: models, toastService: ToastService()),
            cache: AudioStreamCache(modelContainer: models), fetchFavorites: { _ in
                await MainActor.run {
                    switch change {
                    case "server": server.state.activeConnectionVersion = .init(serverID: UUID(), revision: 2)
                    case "offline": server.state.isOfflineModeEnabled = true
                    default: settings.keepFavoritesOffline = false
                    }
                }
                return starred
            })
        await sync.synchronize()
        #expect(sync.error == nil)
        #expect(try await store.snapshot(serverID: id).favorites == nil)
        #expect(try await store.usage().count == 0)
    }

}
