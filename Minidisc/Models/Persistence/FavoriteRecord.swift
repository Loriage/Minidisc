import Foundation
import SwiftData

nonisolated enum FavoriteType: String, CaseIterable, Sendable {
    case song
    case album
    case artist
}

/// Favorites visible locally, including changes not yet sent to the server.
@Model
final class FavoriteRecord {
    @Attribute(.unique) var id: String
    var itemType: String
    var itemId: String
    var starredDate: Date
    var serverId: UUID

    init(itemType: FavoriteType, itemId: String, starredDate: Date, serverId: UUID) {
        self.itemType = itemType.rawValue
        self.itemId = itemId
        self.id = ServerItemIdentity.key(serverID: serverId, type: itemType.rawValue, itemID: itemId)
        self.starredDate = starredDate
        self.serverId = serverId
    }
}

@Model
final class PendingFavoriteChange {
    @Attribute(.unique) var id: String
    var itemType: String
    var itemId: String
    var serverId: UUID
    var isFavorite: Bool
    var revision: UUID

    init(itemType: FavoriteType, itemId: String, serverId: UUID, isFavorite: Bool) {
        id = ServerItemIdentity.key(serverID: serverId, type: itemType.rawValue, itemID: itemId)
        self.itemType = itemType.rawValue
        self.itemId = itemId
        self.serverId = serverId
        self.isFavorite = isFavorite
        revision = UUID()
    }
}
