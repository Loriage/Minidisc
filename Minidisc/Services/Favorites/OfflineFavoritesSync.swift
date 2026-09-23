import Foundation
import Observation
import SwiftSonic
import OSLog

@Observable
@MainActor
final class OfflineFavoritesSync {
    struct Request: Equatable {
        let version: ServerConnection.Version?
        let account: ServerSnapshot?
        let network: NetworkPathEvent
        let isOnline: Bool
        let observedNetwork: Bool
        let enabled: Bool
        let allowsCellular: Bool
        let format: CacheFormat
        let streamQuality: StreamQuality
        let revision: Int
    }

    private(set) var usage = OfflineFavoritesStore.Usage()
    private(set) var isSyncing = false
    private(set) var completed = 0
    private(set) var total = 0
    private(set) var error: UserFacingError?
    var revision = 0

    private let store: OfflineFavoritesStore
    private let settings: CacheSettings
    private let streamSettings: StreamSettings
    private let server: any ServerServiceProtocol
    private let downloads: any DownloadServiceProtocol
    private let cache: any AudioStreamCacheProtocol
    private let artwork: ArtworkImageCache?
    private let transfer: OfflineFavoritesTransfer
    private let fetchFavorites: @Sendable (ServerConnection) async throws -> Starred2
    private let fetchAlbum: @Sendable (ServerConnection, String) async throws -> AlbumID3
    private var runID = UUID()

    var request: Request {
        Request(version: server.state.activeConnectionVersion,
                account: server.state.activeServer,
                network: server.state.networkPathEvent,
                isOnline: server.state.isOnline,
                observedNetwork: server.state.hasObservedNetworkPath,
                enabled: settings.keepFavoritesOffline,
                allowsCellular: settings.cacheOverCellular,
                format: settings.cacheFormat, streamQuality: streamSettings.currentQuality,
                revision: revision)
    }

    var waitingForConnection: Bool { !server.state.isOnline }
    var waitingForWiFi: Bool {
        let path = server.state.networkPathEvent.descriptor
        return !server.state.hasObservedNetworkPath || path.isConstrained
            || (path.isExpensive && !settings.cacheOverCellular)
    }

    init(store: OfflineFavoritesStore, settings: CacheSettings, streamSettings: StreamSettings,
         server: any ServerServiceProtocol, downloads: any DownloadServiceProtocol,
         cache: any AudioStreamCacheProtocol, artwork: ArtworkImageCache? = nil,
         session: URLSession? = nil,
         fetchFavorites: @escaping @Sendable (ServerConnection) async throws -> Starred2 = { try await $0.makeSwiftSonicClient().getStarred2() },
         fetchAlbum: @escaping @Sendable (ServerConnection, String) async throws -> AlbumID3 = { try await $0.makeSwiftSonicClient().getAlbum(id: $1) }) {
        self.store = store
        self.settings = settings
        self.streamSettings = streamSettings
        self.server = server
        self.downloads = downloads
        self.cache = cache
        self.artwork = artwork
        transfer = OfflineFavoritesTransfer(session: session)
        self.fetchFavorites = fetchFavorites
        self.fetchAlbum = fetchAlbum
    }

    func refreshUsage() async {
        if let value = try? await store.usage() { usage = value }
    }

    func synchronize() async {
        let id = UUID()
        runID = id
        let expected = request
        isSyncing = false
        error = nil
        completed = 0
        total = 0
        do {
            try check(expected)
            if !expected.enabled {
                try await store.clearAudio()
            } else if expected.version != nil, !waitingForConnection, !waitingForWiFi {
                isSyncing = true
                try await synchronize(expected)
            }
        } catch {
            if runID == id, !UserFacingError.isCancellation(error) {
                self.error = UserFacingError.from(error)
            }
        }
        guard runID == id else { return }
        isSyncing = false
        await refreshUsage()
    }

    private func synchronize(_ expected: Request) async throws {
        let connection = try await server.activeConnection()
        try check(expected)
        guard connection.version == expected.version,
              connection.server == expected.account
        else { throw CancellationError() }
        let serverID = connection.version.serverID
        let client = connection.makeSwiftSonicClient()
        let favorites = try await fetchFavorites(connection)
        try check(expected)
        var albums: [AlbumID3] = []
        for album in favorites.album ?? [] {
            albums.append(try await fetchAlbum(connection, album.id))
            try check(expected)
        }
        // Only a complete, successful catalogue may remove previously saved favorites.
        let songs = try await store.reconcile(favorites: favorites, albums: albums, serverID: serverID)
        try check(expected)
        total = songs.count
        var covers = Set<String>()
        for song in songs {
            try check(expected)
            do {
                if await store.localURL(songID: song.id, serverID: serverID) == nil {
                    let manual = await downloads.downloadedURL(forSongId: song.id, serverId: serverID)
                    let cached = manual == nil ? await cache.cachedURL(forSongId: song.id, serverId: serverID) : nil
                    if let local = manual ?? cached {
                        try check(expected)
                        try await store.store(fileAt: local, songID: song.id, serverID: serverID)
                    } else {
                        let format = expected.format == .matchStream ? expected.streamQuality.subsonicFormat : expected.format.subsonicFormat
                        let bitrate = expected.format == .matchStream ? expected.streamQuality.subsonicMaxBitRate : expected.format.subsonicMaxBitRate
                        guard let url = client.streamURL(id: song.id, maxBitRate: bitrate, format: format) else {
                            throw UserFacingError.contentRemoved
                        }
                        let request = PlayerService.cacheDownloadRequest(
                            url: url, headers: connection.authorizationHeaders(for: url), allowCellular: expected.allowsCellular
                        )
                        let file = try await transfer.download(request, songID: song.id)
                        defer { try? FileManager.default.removeItem(at: file) }
                        try check(expected)
                        try await store.store(fileAt: file, songID: song.id, serverID: serverID)
                    }
                }
                try check(expected)
                completed += 1
                if let cover = song.coverArt, covers.insert(cover).inserted {
                    _ = await artwork?.load(coverArtId: cover)
                }
            } catch {
                try check(expected)
                self.error = UserFacingError.from(error)
                // Stop on network/storage failures; a later reconnect or retry resumes saved work.
                if self.error != .contentRemoved { throw error }
            }
        }
    }

    private func check(_ expected: Request) throws {
        try Task.checkCancellation()
        guard request == expected else { throw CancellationError() }
    }
}

private actor OfflineFavoritesTransfer {
    private let session: URLSession

    init(session: URLSession?) {
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 3600
            config.allowsConstrainedNetworkAccess = false
            self.session = URLSession(configuration: config)
        }
    }

    func download(_ request: URLRequest, songID: String) async throws -> URL {
        var request = request
        request.allowsExpensiveNetworkAccess = request.allowsCellularAccess
        request.allowsConstrainedNetworkAccess = false
        let (file, response) = try await session.download(for: request)
        do {
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw UserFacingError.downloadFailed
            }
            try AudioResponseValidator.validate(fileAt: file, response: response, songId: songID, logger: Logger.cache)
            return file
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }
}
