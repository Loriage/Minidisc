import Foundation
import SwiftData

/// Historical schema: never edit its persisted fields or constraints. Add a new version instead.
nonisolated enum LibraryIndexSchemaV4: VersionedSchema {
    static let versionIdentifier = Schema.Version(4, 0, 0)
    static var models: [any PersistentModel.Type] {
        LibraryIndexSchemaV3.models + [TrackSearchIndexState.self]
    }

    /// Retained for stores opened by the withdrawn artist-credits build. The current
    /// app does not use this marker, but removing its schema would strand those stores.
    @Model
    nonisolated final class TrackSearchIndexState {
        #Unique<TrackSearchIndexState>([\.serverId])
        var serverId: UUID
        var version: Int

        init(serverId: UUID, version: Int) {
            self.serverId = serverId
            self.version = version
        }
    }
}
