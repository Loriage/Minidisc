import Foundation
import SwiftData

@Model
final class QueueSnapshot {
    var id: UUID
    var serverId: UUID
    var songIds: [String]
    var currentIndex: Int
    var positionSeconds: Double
    var savedAt: Date

    init(
        id: UUID = UUID(),
        serverId: UUID,
        songIds: [String],
        currentIndex: Int,
        positionSeconds: Double,
        savedAt: Date = Date()
    ) {
        self.id = id
        self.serverId = serverId
        self.songIds = songIds
        self.currentIndex = currentIndex
        self.positionSeconds = positionSeconds
        self.savedAt = savedAt
    }
}
