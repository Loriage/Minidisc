import Foundation

nonisolated enum PinError: Error, LocalizedError {
    case limitReached

    var errorDescription: String? {
        switch self {
        case .limitReached: String(localized: "Maximum 6 items can be pinned to Home.")
        }
    }
}

@MainActor
protocol PinServiceProtocol: AnyObject {
    func pin(
        itemType: PinnedItemType,
        itemId: String,
        displayName: String,
        displaySubtitle: String,
        coverArtId: String?,
        serverId: UUID
    ) throws
    func unpin(itemType: PinnedItemType, itemId: String)
    func isPinned(itemType: PinnedItemType, itemId: String) -> Bool
    func reorder(items: [PinnedItem])
    func currentPinnedCount() -> Int
    func updateCoverArtId(itemType: PinnedItemType, itemId: String, newCoverArtId: String?)
}
