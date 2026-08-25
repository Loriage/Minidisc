import Foundation
import SwiftData

@Model
final class CachedTrack {
    var id: UUID
    var songId: String
    var serverId: UUID
    var filePath: String        // relative to Caches/app.minidisc/audio/
    var fileSize: Int64
    var mimeType: String
    /// Updated on insertion and every successful lookup; used as the LRU ordering key.
    var cachedAt: Date

    init(
        id: UUID = UUID(),
        songId: String,
        serverId: UUID,
        filePath: String,
        fileSize: Int64,
        mimeType: String,
        cachedAt: Date = Date()
    ) {
        self.id = id
        self.songId = songId
        self.serverId = serverId
        self.filePath = filePath
        self.fileSize = fileSize
        self.mimeType = mimeType
        self.cachedAt = cachedAt
    }
}
