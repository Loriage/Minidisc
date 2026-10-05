import Foundation
import SwiftData

nonisolated enum PinnedItemType: String, CaseIterable, Sendable {
    case album
    case playlist
}

@Model
final class PinnedItem {
    @Attribute(.unique) var id: String
    var itemType: String
    var itemId: String
    var pinnedDate: Date
    var sortOrder: Int
    var serverId: UUID
    var displayName: String
    var displaySubtitle: String
    var coverArtId: String?

    init(
        itemType: PinnedItemType,
        itemId: String,
        displayName: String,
        displaySubtitle: String,
        coverArtId: String?,
        serverId: UUID,
        sortOrder: Int
    ) {
        self.itemType = itemType.rawValue
        self.itemId = itemId
        self.id = ServerItemIdentity.key(serverID: serverId, type: itemType.rawValue, itemID: itemId)
        self.displayName = displayName
        self.displaySubtitle = displaySubtitle
        self.coverArtId = coverArtId
        self.serverId = serverId
        self.sortOrder = sortOrder
        self.pinnedDate = Date()
    }
}
