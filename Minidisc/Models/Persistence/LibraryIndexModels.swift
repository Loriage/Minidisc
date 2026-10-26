import SwiftData

// Active model aliases. Historical schemas reference their own immutable model types,
// never these aliases. A persisted change needs a new schema and migration stage.
typealias IndexedTrack = LibraryIndexSchemaV1.IndexedTrack
typealias IndexedAlbum = LibraryIndexSchemaV1.IndexedAlbum
typealias IndexedArtist = LibraryIndexSchemaV1.IndexedArtist
typealias LibraryIndexState = LibraryIndexSchemaV1.LibraryIndexState
typealias IndexedPlaylist = LibraryIndexSchemaV2.IndexedPlaylist
typealias PlaylistIndexState = LibraryIndexSchemaV2.PlaylistIndexState
typealias IndexedAlbumRecommendation = LibraryIndexSchemaV3.IndexedAlbumRecommendation

nonisolated enum LibraryIndexMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [LibraryIndexSchemaV1.self, LibraryIndexSchemaV2.self, LibraryIndexSchemaV3.self, LibraryIndexSchemaV4.self]
    }

    static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: LibraryIndexSchemaV1.self, toVersion: LibraryIndexSchemaV2.self),
            .lightweight(fromVersion: LibraryIndexSchemaV2.self, toVersion: LibraryIndexSchemaV3.self),
            .lightweight(fromVersion: LibraryIndexSchemaV3.self, toVersion: LibraryIndexSchemaV4.self)
        ]
    }
}
