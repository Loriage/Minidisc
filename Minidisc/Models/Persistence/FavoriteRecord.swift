import Foundation
import SwiftData

nonisolated enum FavoriteType: String, CaseIterable, Sendable {
    case song
    case album
    case artist
}

/// Local cache of server-side starred items. Synced from getStarred2 on launch
/// and updated optimistically on star/unstar actions.
@Model
final class FavoriteRecord {
    @Attribute(.unique) var id: String  // "{serverId}:{type}:{itemId}"
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
