import Foundation
import SwiftData

/// Historical schema: never edit its persisted fields or constraints. Add a new version instead.
nonisolated enum LibraryIndexSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] {
        LibraryIndexSchemaV1.models + [IndexedPlaylist.self, PlaylistIndexState.self]
    }

    /// One server playlist summary plus an opportunistic detail snapshot. The summary payload from
    /// the detail request is retained separately so callers can distinguish a current detail from a
    /// stale-but-usable offline fallback after the server list changes.
    @Model
    nonisolated final class IndexedPlaylist {
        #Unique<IndexedPlaylist>([\.recordKey])
        #Index<IndexedPlaylist>(
            [\.serverId],
            [\.serverId, \.sortName],
            [\.serverId, \.serverOrder]
        )

        var recordKey: String
        var serverId: UUID
        var itemId: String
        var name: String
        var sortName: String
        var serverOrder: Int
        var generation: String
        var summaryPayload: Data
        var detailPayload: Data?
        var detailSummaryPayload: Data?

        init(
            recordKey: String,
            serverId: UUID,
            itemId: String,
            name: String,
            sortName: String,
            serverOrder: Int,
            generation: String,
            summaryPayload: Data,
            detailPayload: Data? = nil,
            detailSummaryPayload: Data? = nil
        ) {
            self.recordKey = recordKey
            self.serverId = serverId
            self.itemId = itemId
            self.name = name
            self.sortName = sortName
            self.serverOrder = serverOrder
            self.generation = generation
            self.summaryPayload = summaryPayload
            self.detailPayload = detailPayload
            self.detailSummaryPayload = detailSummaryPayload
        }
    }

    /// Kept separate from `LibraryIndexState` so the V1 artist/album/track schema remains unchanged
    /// and can migrate to playlist indexing with a lightweight additive migration.
    @Model
    nonisolated final class PlaylistIndexState {
        #Unique<PlaylistIndexState>([\.serverId])
        #Index<PlaylistIndexState>([\.serverId])

        var serverId: UUID
        var syncedAt: Date?

        init(serverId: UUID, syncedAt: Date? = nil) {
            self.serverId = serverId
            self.syncedAt = syncedAt
        }
    }
}
