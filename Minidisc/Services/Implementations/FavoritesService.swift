import Foundation
import SwiftData
import SwiftSonic

extension SwiftSonicClient: FavoriteEditing {
    func getStarred2() async throws -> Starred2 { try await getStarred2(musicFolderId: nil) }
}

actor FavoritesService: FavoritesServiceProtocol, StarredBrowsing {
    private let server: any ServerServiceProtocol
    private let offlineStore: OfflineFavoritesStore
    private let offlineReader: OfflineBrowsingReader?
    private let clientFactory: @Sendable (ServerConnection) -> any FavoriteEditing
    nonisolated let modelContainer: ModelContainer
    private lazy var context = ModelContext(modelContainer)
    private var revision: UInt64 = 0
    private var refreshes: [UUID: (version: ServerConnection.Version, task: Task<Starred2, Error>)] = [:]

    init(server: any ServerServiceProtocol, modelContainer: ModelContainer,
         offlineStore: OfflineFavoritesStore, offlineReader: OfflineBrowsingReader? = nil,
         clientFactory: @escaping @Sendable (ServerConnection) -> any FavoriteEditing = { $0.makeSwiftSonicClient() }) {
        self.server = server
        self.modelContainer = modelContainer
        self.offlineStore = offlineStore
        self.offlineReader = offlineReader
        self.clientFactory = clientFactory
    }

    @MainActor
    func isFavorite(itemType: FavoriteType, itemId: String) -> Bool {
        guard let serverId = server.state.activeServer?.id else { return false }
        let id = ServerItemIdentity.key(serverID: serverId, type: itemType.rawValue, itemID: itemId)
        return (try? modelContainer.mainContext.fetchCount(FetchDescriptor<FavoriteRecord>(
            predicate: #Predicate { $0.id == id }
        ))) ?? 0 > 0
    }

    func star(itemType: FavoriteType, itemId: String) async throws {
        try await change(itemType: itemType, itemId: itemId, isFavorite: true)
    }

    func unstar(itemType: FavoriteType, itemId: String) async throws {
        try await change(itemType: itemType, itemId: itemId, isFavorite: false)
    }

    private func change(itemType: FavoriteType, itemId: String, isFavorite: Bool) async throws {
        guard let serverID = await server.state.activeServer?.id else { throw MinidiscError.serverNotConfigured }
        let id = ServerItemIdentity.key(serverID: serverID, type: itemType.rawValue, itemID: itemId)
        let record = try context.fetch(FetchDescriptor<FavoriteRecord>(predicate: #Predicate { $0.id == id })).first
        if isFavorite, record == nil {
            context.insert(FavoriteRecord(itemType: itemType, itemId: itemId, starredDate: Date(), serverId: serverID))
        } else if !isFavorite, let record {
            context.delete(record)
        }
        if let pending = try context.fetch(FetchDescriptor<PendingFavoriteChange>(predicate: #Predicate { $0.id == id })).first {
            pending.isFavorite = isFavorite
            pending.revision = UUID()
        } else {
            context.insert(PendingFavoriteChange(itemType: itemType, itemId: itemId, serverId: serverID, isFavorite: isFavorite))
        }
        try save()
        revision &+= 1
        await MainActor.run {
            NotificationCenter.default.post(name: .minidiscFavoritesChanged, object: nil)
            postOfflineLibraryChanged()
        }
        guard await server.state.isOnline,
              let connection = try? await server.activeConnection(), connection.server.id == serverID else { return }
        do { _ = try await refreshedFavorites(for: connection) }
        catch {
            // A lost response may follow a successful write. Replaying star/unstar is idempotent.
            if !Self.canRetryLater(error), !UserFacingError.isCancellation(error) { throw error }
        }
    }

    func syncFromServer() async throws {
        guard await server.state.isOnline, await server.state.activeServer != nil else { return }
        _ = try await refreshedFavorites(for: server.activeConnection())
    }

    func getStarred2() async throws -> Starred2 {
        guard let serverID = await server.state.activeServer?.id else { throw MinidiscError.serverNotConfigured }
        if await !server.state.isOnline { return try await cachedFavorites(serverID: serverID) }
        do { return try await refreshedFavorites(for: server.activeConnection()) }
        catch {
            guard Self.canRetryLater(error), await server.state.activeServer?.id == serverID else { throw error }
            let saved = try await offlineStore.snapshot(serverID: serverID)
            let hasPendingChanges = try !pendingChanges(serverID: serverID).isEmpty
            guard saved.favorites != nil || hasPendingChanges else { throw error }
            return try await cachedFavorites(serverID: serverID)
        }
    }

    func refreshedFavorites(for connection: ServerConnection) async throws -> Starred2 {
        try await check(connection)
        let serverID = connection.server.id
        if let current = refreshes[serverID] {
            if current.version == connection.version { return try await current.task.value }
            _ = try? await current.task.value
            return try await refreshedFavorites(for: connection)
        }
        let task = Task {
            defer { refreshes[serverID] = nil }
            return try await synchronize(connection)
        }
        refreshes[serverID] = (connection.version, task)
        return try await task.value
    }

    private func synchronize(_ connection: ServerConnection) async throws -> Starred2 {
        let serverID = connection.server.id
        let client = clientFactory(connection)
        var sent: [String: UUID] = [:]
        while true {
            try await check(connection)
            while let pending = try pendingChanges(serverID: serverID).first(where: { sent[$0.id] != $0.revision }) {
                let id = pending.id
                let sentRevision = pending.revision
                let songs = pending.itemType == FavoriteType.song.rawValue ? [pending.itemId] : []
                let albums = pending.itemType == FavoriteType.album.rawValue ? [pending.itemId] : []
                let artists = pending.itemType == FavoriteType.artist.rawValue ? [pending.itemId] : []
                if pending.isFavorite { try await client.star(songIds: songs, albumIds: albums, artistIds: artists) }
                else { try await client.unstar(songIds: songs, albumIds: albums, artistIds: artists) }
                try await check(connection)
                sent[id] = sentRevision
            }
            let requestedRevision = revision
            let favorites = try await client.getStarred2()
            try await check(connection)
            // A tap during the request makes its response stale, even if the write already finished.
            guard revision == requestedRevision else { continue }
            try await offlineStore.saveFavorites(favorites, serverID: serverID)
            try await check(connection)
            guard revision == requestedRevision else { continue }
            for change in try pendingChanges(serverID: serverID) where sent[change.id] == change.revision {
                context.delete(change)
            }
            try apply(favorites, serverID: serverID)
            return favorites
        }
    }

    private func cachedFavorites(serverID: UUID) async throws -> Starred2 {
        let saved = try await offlineStore.snapshot(serverID: serverID).favorites
        let local = try await offlineReader?.read(serverID: serverID).favorites
        try Task.checkCancellation()
        guard await server.state.activeServer?.id == serverID else { throw CancellationError() }
        let changes = try pendingChanges(serverID: serverID)
        func overlay<T>(_ saved: [T], _ local: [T], type: FavoriteType, id: (T) -> String) -> [T] {
            var values = Dictionary(saved.map { (id($0), $0) }, uniquingKeysWith: { first, _ in first })
            let available = Dictionary(local.map { (id($0), $0) }, uniquingKeysWith: { first, _ in first })
            for change in changes where change.itemType == type.rawValue {
                if change.isFavorite { values[change.itemId] = values[change.itemId] ?? available[change.itemId] }
                else { values[change.itemId] = nil }
            }
            return Array(values.values)
        }
        struct Payload: Encodable {
            let artist: [ArtistID3]
            let album: [AlbumID3]
            let song: [Song]
        }
        let payload = Payload(
            artist: overlay(saved?.artist ?? [], local?.artists ?? [], type: .artist, id: { $0.id }),
            album: overlay(saved?.album ?? [], local?.albums ?? [], type: .album, id: { $0.id }),
            song: overlay(saved?.song ?? [], local?.songs ?? [], type: .song, id: { $0.id })
        )
        return try JSONDecoder().decode(Starred2.self, from: JSONEncoder().encode(payload))
    }

    private func apply(_ favorites: Starred2, serverID: UUID) throws {
        let existing = try context.fetch(FetchDescriptor<FavoriteRecord>(predicate: #Predicate { $0.serverId == serverID }))
        let ids = Set(existing.map(\.id))
        var desired = Set<String>()
        func include(_ type: FavoriteType, _ itemID: String) {
            let id = ServerItemIdentity.key(serverID: serverID, type: type.rawValue, itemID: itemID)
            guard desired.insert(id).inserted, !ids.contains(id) else { return }
            context.insert(FavoriteRecord(itemType: type, itemId: itemID, starredDate: Date(), serverId: serverID))
        }
        for song in favorites.song ?? [] { include(.song, song.id) }
        for album in favorites.album ?? [] { include(.album, album.id) }
        for artist in favorites.artist ?? [] { include(.artist, artist.id) }
        for record in existing where !desired.contains(record.id) { context.delete(record) }
        try save()
    }

    private func pendingChanges(serverID: UUID) throws -> [PendingFavoriteChange] {
        try context.fetch(FetchDescriptor<PendingFavoriteChange>(predicate: #Predicate { $0.serverId == serverID }))
    }

    private func check(_ connection: ServerConnection) async throws {
        try Task.checkCancellation()
        guard await server.activeConnectionVersion() == connection.version,
              await server.state.isOnline else { throw CancellationError() }
    }

    private nonisolated static func canRetryLater(_ error: any Error) -> Bool {
        let error = UserFacingError.from(error)
        return error == .noNetwork || error == .serverUnreachable || error == .contentUnavailableOffline
    }

    private func save() throws {
        do { try context.save() }
        catch { context.rollback(); throw error }
    }
}
