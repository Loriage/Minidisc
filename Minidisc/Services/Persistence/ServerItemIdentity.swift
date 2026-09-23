import Foundation
import SwiftData

nonisolated enum ServerItemIdentity {
    static func key(serverID: UUID, type: String, itemID: String) -> String {
        "\(serverID.uuidString):\(type):\(itemID)"
    }

    /// String-key migration only: retain dates, ordering, artwork and ownership.
    /// Running on every open also makes interrupted upgrades safe to retry.
    @MainActor
    static func migrate(in container: ModelContainer) throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        for item in try context.fetch(FetchDescriptor<FavoriteRecord>()) {
            let id = key(serverID: item.serverId, type: item.itemType, itemID: item.itemId)
            if item.id != id { item.id = id }
        }
        for item in try context.fetch(FetchDescriptor<PinnedItem>()) {
            let id = key(serverID: item.serverId, type: item.itemType, itemID: item.itemId)
            if item.id != id { item.id = id }
        }
        if context.hasChanges { try context.save() }
    }
}
