import Foundation
import SwiftData

/// Historical schema: never edit its persisted fields or constraints. Add a new version instead.
nonisolated enum LibraryIndexSchemaV3: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)
    static var models: [any PersistentModel.Type] {
        LibraryIndexSchemaV2.models + [IndexedAlbumRecommendation.self]
    }

    /// Derived album recommendations cached per server and source album. An empty payload is a
    /// meaningful negative result: it prevents an absent section from briefly appearing on revisit.
    @Model
    nonisolated final class IndexedAlbumRecommendation {
        #Unique<IndexedAlbumRecommendation>([\.recordKey])
        #Index<IndexedAlbumRecommendation>(
            [\.serverId],
            [\.serverId, \.sourceAlbumId],
            [\.serverId, \.refreshedAt]
        )

        var recordKey: String
        var serverId: UUID
        var sourceAlbumId: String
        var refreshedAt: Date
        var requestedLimit: Int
        var payload: Data

        init(
            recordKey: String,
            serverId: UUID,
            sourceAlbumId: String,
            refreshedAt: Date,
            requestedLimit: Int,
            payload: Data
        ) {
            self.recordKey = recordKey
            self.serverId = serverId
            self.sourceAlbumId = sourceAlbumId
            self.refreshedAt = refreshedAt
            self.requestedLimit = requestedLimit
            self.payload = payload
        }
    }
}
