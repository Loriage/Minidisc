import Foundation
import SwiftData
import OSLog

@MainActor
final class PinService: PinServiceProtocol {
    private let modelContext: ModelContext
    private let serverState: ServerState
    private static let maxPinnedItems = 6

    init(modelContainer: ModelContainer, serverState: ServerState) {
        self.serverState = serverState
        // Keep pin writes out of the main SwiftData observation graph.
        let ctx = ModelContext(modelContainer)
        ctx.autosaveEnabled = false
        self.modelContext = ctx
    }

    func isPinned(itemType: PinnedItemType, itemId: String) -> Bool {
        guard let serverId = serverState.activeServer?.id else { return false }
        let compositeId = ServerItemIdentity.key(serverID: serverId, type: itemType.rawValue, itemID: itemId)
        var descriptor = FetchDescriptor<PinnedItem>(
            predicate: #Predicate<PinnedItem> { $0.id == compositeId }
        )
        descriptor.fetchLimit = 1
        return (try? modelContext.fetchCount(descriptor)) ?? 0 > 0
    }

    func currentPinnedCount() -> Int {
        guard let serverId = serverState.activeServer?.id else { return 0 }
        return pinnedCount(serverId: serverId)
    }

    private func pinnedCount(serverId: UUID) -> Int {
        let descriptor = FetchDescriptor<PinnedItem>(predicate: #Predicate { $0.serverId == serverId })
        return (try? modelContext.fetchCount(descriptor)) ?? 0
    }

    func pin(
        itemType: PinnedItemType,
        itemId: String,
        displayName: String,
        displaySubtitle: String,
        coverArtId: String?,
        serverId: UUID
    ) throws {
        let compositeId = ServerItemIdentity.key(serverID: serverId, type: itemType.rawValue, itemID: itemId)
        var existingDescriptor = FetchDescriptor<PinnedItem>(
            predicate: #Predicate<PinnedItem> { $0.id == compositeId }
        )
        existingDescriptor.fetchLimit = 1
        if (try? modelContext.fetchCount(existingDescriptor)) ?? 0 > 0 { return }

        let count = pinnedCount(serverId: serverId)
        guard count < PinService.maxPinnedItems else { throw PinError.limitReached }

        let item = PinnedItem(
            itemType: itemType,
            itemId: itemId,
            displayName: displayName,
            displaySubtitle: displaySubtitle,
            coverArtId: coverArtId,
            serverId: serverId,
            sortOrder: count
        )
        modelContext.insert(item)
        do { try modelContext.save() }
        catch { modelContext.rollback(); throw error }
        Logger.pin.info("Pinned \(itemType.rawValue, privacy: .public) \(itemId, privacy: .public) at position \(count, privacy: .public)")
    }

    func unpin(itemType: PinnedItemType, itemId: String) {
        guard let serverId = serverState.activeServer?.id else { return }
        let compositeId = ServerItemIdentity.key(serverID: serverId, type: itemType.rawValue, itemID: itemId)
        var descriptor = FetchDescriptor<PinnedItem>(
            predicate: #Predicate<PinnedItem> { $0.id == compositeId }
        )
        descriptor.fetchLimit = 1
        guard let item = try? modelContext.fetch(descriptor).first else { return }

        modelContext.delete(item)

        let allDescriptor = FetchDescriptor<PinnedItem>(
            predicate: #Predicate { $0.serverId == serverId },
            sortBy: [SortDescriptor(\PinnedItem.sortOrder)]
        )
        let remaining = (try? modelContext.fetch(allDescriptor)) ?? []
        for (index, pinned) in remaining.enumerated() {
            pinned.sortOrder = index
        }

        try? modelContext.save()
        Logger.pin.info("Unpinned \(itemType.rawValue, privacy: .public) \(itemId, privacy: .public)")
    }

    func updateCoverArtId(itemType: PinnedItemType, itemId: String, newCoverArtId: String?) {
        guard let serverId = serverState.activeServer?.id else { return }
        let compositeId = ServerItemIdentity.key(serverID: serverId, type: itemType.rawValue, itemID: itemId)
        var descriptor = FetchDescriptor<PinnedItem>(
            predicate: #Predicate<PinnedItem> { $0.id == compositeId }
        )
        descriptor.fetchLimit = 1
        guard let item = try? modelContext.fetch(descriptor).first else { return }
        item.coverArtId = newCoverArtId
        try? modelContext.save()
        Logger.pin.debug("Updated coverArtId for \(itemType.rawValue, privacy: .public) \(itemId, privacy: .public) → \(newCoverArtId ?? "<nil>", privacy: .public)")
    }

    func reorder(items: [PinnedItem]) {
        guard let serverId = serverState.activeServer?.id else { return }
        let records = (try? modelContext.fetch(FetchDescriptor<PinnedItem>(predicate: #Predicate { $0.serverId == serverId }))) ?? []
        let order = Dictionary(items.filter { $0.serverId == serverId }.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        for record in records {
            if let index = order[record.id] { record.sortOrder = index }
        }
        try? modelContext.save()
        Logger.pin.info("Reordered \(items.count, privacy: .public) pinned items")
    }
}
