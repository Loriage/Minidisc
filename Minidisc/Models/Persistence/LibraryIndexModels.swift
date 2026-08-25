import Foundation
import SwiftData

/// Searchable metadata for one server track. The encoded payload preserves the exact
/// SwiftSonic value while the scalar columns keep local queries cheap and typed.
@Model
nonisolated final class IndexedTrack {
    #Unique<IndexedTrack>([\.recordKey])
    #Index<IndexedTrack>(
        [\.serverId],
        [\.serverId, \.albumId],
        [\.serverId, \.artistId],
        [\.serverId, \.serverOrder]
    )

    var recordKey: String
    var serverId: UUID
    var itemId: String
    var title: String
    var albumName: String?
    var artistName: String?
    var albumId: String?
    var artistId: String?
    var searchText: String
    var sortTitle: String
    var serverOrder: Int?
    var createdAt: Date?
    var generation: String
    var payload: Data

    init(
        recordKey: String,
        serverId: UUID,
        itemId: String,
        title: String,
        albumName: String?,
        artistName: String?,
        albumId: String?,
        artistId: String?,
        searchText: String,
        sortTitle: String,
        serverOrder: Int?,
        createdAt: Date?,
        generation: String,
        payload: Data
    ) {
        self.recordKey = recordKey
        self.serverId = serverId
        self.itemId = itemId
        self.title = title
        self.albumName = albumName
        self.artistName = artistName
        self.albumId = albumId
        self.artistId = artistId
        self.searchText = searchText
        self.sortTitle = sortTitle
        self.serverOrder = serverOrder
        self.createdAt = createdAt
        self.generation = generation
        self.payload = payload
    }
}

/// Searchable metadata for one server album.
@Model
nonisolated final class IndexedAlbum {
    #Unique<IndexedAlbum>([\.recordKey])
    #Index<IndexedAlbum>(
        [\.serverId],
        [\.serverId, \.artistId],
        [\.serverId, \.createdAt]
    )

    var recordKey: String
    var serverId: UUID
    var itemId: String
    var name: String
    var artistName: String?
    var artistId: String?
    var searchText: String
    var sortName: String
    var createdAt: Date?
    var generation: String
    var payload: Data

    init(
        recordKey: String,
        serverId: UUID,
        itemId: String,
        name: String,
        artistName: String?,
        artistId: String?,
        searchText: String,
        sortName: String,
        createdAt: Date?,
        generation: String,
        payload: Data
    ) {
        self.recordKey = recordKey
        self.serverId = serverId
        self.itemId = itemId
        self.name = name
        self.artistName = artistName
        self.artistId = artistId
        self.searchText = searchText
        self.sortName = sortName
        self.createdAt = createdAt
        self.generation = generation
        self.payload = payload
    }
}

/// Searchable metadata for one server artist, including the server-provided index bucket.
@Model
nonisolated final class IndexedArtist {
    #Unique<IndexedArtist>([\.recordKey])
    #Index<IndexedArtist>([\.serverId], [\.serverId, \.normalizedName])

    var recordKey: String
    var serverId: UUID
    var itemId: String
    var name: String
    var normalizedName: String
    var indexName: String
    var searchText: String
    var sortName: String
    var generation: String
    var payload: Data

    init(
        recordKey: String,
        serverId: UUID,
        itemId: String,
        name: String,
        normalizedName: String,
        indexName: String,
        searchText: String,
        sortName: String,
        generation: String,
        payload: Data
    ) {
        self.recordKey = recordKey
        self.serverId = serverId
        self.itemId = itemId
        self.name = name
        self.normalizedName = normalizedName
        self.indexName = indexName
        self.searchText = searchText
        self.sortName = sortName
        self.generation = generation
        self.payload = payload
    }
}

/// Completion markers are independent so a failed track scan cannot invalidate a
/// successfully refreshed album or artist index.
@Model
nonisolated final class LibraryIndexState {
    #Unique<LibraryIndexState>([\.serverId])
    #Index<LibraryIndexState>([\.serverId])

    var serverId: UUID
    var artistsSyncedAt: Date?
    var albumsSyncedAt: Date?
    var tracksSyncedAt: Date?

    init(serverId: UUID) {
        self.serverId = serverId
    }
}

nonisolated enum LibraryIndexSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] {
        [IndexedTrack.self, IndexedAlbum.self, IndexedArtist.self, LibraryIndexState.self]
    }
}

nonisolated enum LibraryIndexMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [LibraryIndexSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}
