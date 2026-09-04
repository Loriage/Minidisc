import Foundation
import SwiftData
import SwiftSonic
import OSLog

actor FavoritesService: FavoritesServiceProtocol {
    private let libraryService: any FavoriteEditing
    private nonisolated let serverState: ServerState
    nonisolated let modelContainer: ModelContainer
    private lazy var backgroundContext: ModelContext = ModelContext(modelContainer)

    init(libraryService: any FavoriteEditing, serverState: ServerState, modelContainer: ModelContainer) {
        self.libraryService = libraryService
        self.serverState = serverState
        self.modelContainer = modelContainer
    }

    // MARK: - Query

    @MainActor
    func isFavorite(itemType: FavoriteType, itemId: String) -> Bool {
        let compositeId = "\(itemType.rawValue):\(itemId)"
        var descriptor = FetchDescriptor<FavoriteRecord>(
            predicate: #Predicate<FavoriteRecord> { $0.id == compositeId }
        )
        descriptor.fetchLimit = 1
        return (try? modelContainer.mainContext.fetchCount(descriptor)) ?? 0 > 0
    }

    // MARK: - Star

    func star(itemType: FavoriteType, itemId: String) async throws {
        guard let serverId = await MainActor.run(body: { serverState.activeServer?.id }) else { throw MinidiscError.serverNotConfigured }

        let record = FavoriteRecord(itemType: itemType, itemId: itemId, starredDate: Date(), serverId: serverId)
        backgroundContext.insert(record)
        try saveChanges()

        do {
            switch itemType {
            case .song:   try await libraryService.star(songIds: [itemId], albumIds: [], artistIds: [])
            case .album:  try await libraryService.star(songIds: [], albumIds: [itemId], artistIds: [])
            case .artist: try await libraryService.star(songIds: [], albumIds: [], artistIds: [itemId])
            }
            Logger.favorites.info("Starred \(itemType.rawValue, privacy: .public) \(itemId, privacy: .public)")
        } catch {
            backgroundContext.delete(record)
            try saveChanges()
            throw error
        }
    }

    // MARK: - Unstar

    func unstar(itemType: FavoriteType, itemId: String) async throws {
        let compositeId = "\(itemType.rawValue):\(itemId)"
        var descriptor = FetchDescriptor<FavoriteRecord>(
            predicate: #Predicate<FavoriteRecord> { $0.id == compositeId }
        )
        descriptor.fetchLimit = 1
        guard let record = try backgroundContext.fetch(descriptor).first else { return }

        let capturedServerId = record.serverId
        let capturedDate = record.starredDate
        backgroundContext.delete(record)
        try saveChanges()

        do {
            switch itemType {
            case .song:   try await libraryService.unstar(songIds: [itemId], albumIds: [], artistIds: [])
            case .album:  try await libraryService.unstar(songIds: [], albumIds: [itemId], artistIds: [])
            case .artist: try await libraryService.unstar(songIds: [], albumIds: [], artistIds: [itemId])
            }
            Logger.favorites.info("Unstarred \(itemType.rawValue, privacy: .public) \(itemId, privacy: .public)")
        } catch {
            let restored = FavoriteRecord(itemType: itemType, itemId: itemId, starredDate: capturedDate, serverId: capturedServerId)
            backgroundContext.insert(restored)
            try saveChanges()
            throw error
        }
    }

    // MARK: - Sync

    func syncFromServer() async throws {
        guard let serverId = await MainActor.run(body: { serverState.activeServer?.id }) else { return }

        let starred = try await libraryService.getStarred2()
        try Task.checkCancellation()
        guard await MainActor.run(body: { serverState.activeServer?.id }) == serverId else { throw CancellationError() }

        let descriptor = FetchDescriptor<FavoriteRecord>(
            predicate: #Predicate<FavoriteRecord> { $0.serverId == serverId }
        )
        let existing = try backgroundContext.fetch(descriptor)
        let existingIds = Set(existing.map(\.id))

        var newIds = Set<String>()
        var added = 0
        var unchanged = 0

        func upsert(type: FavoriteType, itemId: String) {
            let compositeId = "\(type.rawValue):\(itemId)"
            newIds.insert(compositeId)
            if existingIds.contains(compositeId) {
                unchanged += 1
            } else {
                backgroundContext.insert(FavoriteRecord(itemType: type, itemId: itemId, starredDate: Date(), serverId: serverId))
                added += 1
            }
        }

        for song in starred.song ?? []     { upsert(type: .song,   itemId: song.id) }
        for album in starred.album ?? []   { upsert(type: .album,  itemId: album.id) }
        for artist in starred.artist ?? [] { upsert(type: .artist, itemId: artist.id) }

        let toRemove = existing.filter { !newIds.contains($0.id) }
        toRemove.forEach { backgroundContext.delete($0) }

        try saveChanges()
        Logger.favorites.info("Favorites synced: \(added, privacy: .public) added, \(toRemove.count, privacy: .public) removed, \(unchanged, privacy: .public) unchanged")
    }
    private func saveChanges() throws {
        do { try backgroundContext.save() }
        catch { backgroundContext.rollback(); throw error }
    }

}
