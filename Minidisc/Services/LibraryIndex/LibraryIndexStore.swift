import Foundation
import OSLog
import SwiftData
import SwiftSonic

nonisolated enum LibraryIndexKind: String, Sendable {
    case artists
    case albums
    case tracks
    case playlists
}

nonisolated enum LibraryIndexError: Error, Equatable, LocalizedError {
    case suspiciousEmptyResponse(LibraryIndexKind)
    case paginationDidNotAdvance(LibraryIndexKind, offset: Int)

    var errorDescription: String? {
        switch self {
        case .suspiciousEmptyResponse(let kind):
            "The server returned an empty \(kind.rawValue) index while a non-empty local index exists."
        case .paginationDidNotAdvance(let kind, let offset):
            "The server repeated the \(kind.rawValue) page at offset \(offset)."
        }
    }
}

nonisolated struct LibraryIndexStatus: Sendable, Equatable {
    let artistsSyncedAt: Date?
    let albumsSyncedAt: Date?
    let tracksSyncedAt: Date?
    let playlistsSyncedAt: Date?

    var artists: Bool { artistsSyncedAt != nil }
    var albums: Bool { albumsSyncedAt != nil }
    var tracks: Bool { tracksSyncedAt != nil }
    var playlists: Bool { playlistsSyncedAt != nil }

    var libraryIsComplete: Bool { artists && albums && tracks }
    var isComplete: Bool { libraryIsComplete && playlists }

    var librarySyncedAt: Date? {
        guard let artistsSyncedAt, let albumsSyncedAt, let tracksSyncedAt else { return nil }
        return min(artistsSyncedAt, albumsSyncedAt, tracksSyncedAt)
    }

    /// The oldest entity watermark is the point through which the whole index is known complete.
    var fullySyncedAt: Date? {
        guard let librarySyncedAt, let playlistsSyncedAt else { return nil }
        return min(librarySyncedAt, playlistsSyncedAt)
    }
}

nonisolated struct LibraryIndexCounts: Sendable, Equatable {
    let artists: Int
    let albums: Int
    let tracks: Int
    let playlists: Int
}

nonisolated struct LibraryIndexStorageUsage: Sendable, Equatable {
    static let empty = LibraryIndexStorageUsage(
        artists: 0,
        albums: 0,
        tracks: 0,
        playlists: 0,
        recommendationAlbums: 0,
        persistentBytes: 0
    )

    let artists: Int
    let albums: Int
    let tracks: Int
    let playlists: Int
    /// Number of source albums for which a recommendation result — including an empty result — is cached.
    let recommendationAlbums: Int
    let persistentBytes: Int64
}

nonisolated struct CachedAlbumRecommendations: Sendable, Equatable {
    let albums: [AlbumID3]
    let refreshedAt: Date
    let requestedLimit: Int

    func isFresh(at date: Date, lifetime: TimeInterval) -> Bool {
        date.timeIntervalSince(refreshedAt) < lifetime
    }

    func canSatisfy(limit: Int) -> Bool {
        requestedLimit >= limit || albums.count < requestedLimit
    }
}

nonisolated struct LibraryIndexSearchResults: Sendable {
    let artists: [ArtistID3]
    let albums: [AlbumID3]
    let songs: [Song]

    var isEmpty: Bool { artists.isEmpty && albums.isEmpty && songs.isEmpty }
}

nonisolated struct LibraryIndexedPlaylistDetail: Sendable {
    let playlist: PlaylistWithSongs
    let isCurrent: Bool
}

/// SwiftSonic intentionally exposes playlists as decode-only response types. This local boundary
/// type preserves every field with Codable storage without widening the values to dictionaries.
nonisolated struct IndexedPlaylistPayload: Codable, Sendable {
    let id: String
    let name: String
    let comment: String?
    let owner: String?
    let isPublic: Bool?
    let songCount: Int
    let duration: Int
    let created: Date?
    let changed: Date?
    let coverArt: String?
    let entry: [Song]?

    init(_ playlist: Playlist) {
        id = playlist.id
        name = playlist.name
        comment = playlist.comment
        owner = playlist.owner
        isPublic = playlist.isPublic
        songCount = playlist.songCount
        duration = playlist.duration
        created = playlist.created
        changed = playlist.changed
        coverArt = playlist.coverArt
        entry = nil
    }

    init(_ playlist: PlaylistWithSongs) {
        id = playlist.id
        name = playlist.name
        comment = playlist.comment
        owner = playlist.owner
        isPublic = playlist.isPublic
        songCount = playlist.songCount
        duration = playlist.duration
        created = playlist.created
        changed = playlist.changed
        coverArt = playlist.coverArt
        entry = playlist.entry
    }

    var summary: Playlist {
        Playlist(
            id: id,
            name: name,
            songCount: songCount,
            duration: duration,
            comment: comment,
            owner: owner,
            isPublic: isPublic,
            created: created,
            changed: changed,
            coverArt: coverArt
        )
    }

    var detail: PlaylistWithSongs {
        PlaylistWithSongs(
            id: id,
            name: name,
            songCount: songCount,
            duration: duration,
            comment: comment,
            owner: owner,
            isPublic: isPublic,
            created: created,
            changed: changed,
            coverArt: coverArt,
            entry: entry
        )
    }
}

nonisolated enum LibraryIndexText {
    static func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func searchText(_ values: String?...) -> String {
        normalized(values.compactMap { $0 }.joined(separator: " "))
    }
}

/// Owns every SwiftData context and model instance used by the library index.
/// Only immutable SwiftSonic values cross this actor's interface.
actor LibraryIndexStore {
    private let modelContainer: ModelContainer
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private let decoder = JSONDecoder()
    private var removedServerIDs: Set<UUID> = []

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    // MARK: - State

    func status(for serverID: UUID) throws -> LibraryIndexStatus {
        let context = ModelContext(modelContainer)
        let state = try state(for: serverID, in: context)
        let playlistState = try playlistState(for: serverID, in: context)
        return LibraryIndexStatus(
            artistsSyncedAt: state?.artistsSyncedAt,
            albumsSyncedAt: state?.albumsSyncedAt,
            tracksSyncedAt: state?.tracksSyncedAt,
            playlistsSyncedAt: playlistState?.syncedAt
        )
    }

    func counts(for serverID: UUID) throws -> LibraryIndexCounts {
        let context = ModelContext(modelContainer)
        let sid = serverID
        return try LibraryIndexCounts(
            artists: context.fetchCount(
                FetchDescriptor<IndexedArtist>(predicate: #Predicate { $0.serverId == sid })
            ),
            albums: context.fetchCount(
                FetchDescriptor<IndexedAlbum>(predicate: #Predicate { $0.serverId == sid })
            ),
            tracks: context.fetchCount(
                FetchDescriptor<IndexedTrack>(predicate: #Predicate { $0.serverId == sid })
            ),
            playlists: context.fetchCount(
                FetchDescriptor<IndexedPlaylist>(predicate: #Predicate { $0.serverId == sid })
            )
        )
    }

    func storageUsage() throws -> LibraryIndexStorageUsage {
        let context = ModelContext(modelContainer)
        return try LibraryIndexStorageUsage(
            artists: context.fetchCount(FetchDescriptor<IndexedArtist>()),
            albums: context.fetchCount(FetchDescriptor<IndexedAlbum>()),
            tracks: context.fetchCount(FetchDescriptor<IndexedTrack>()),
            playlists: context.fetchCount(FetchDescriptor<IndexedPlaylist>()),
            recommendationAlbums: context.fetchCount(FetchDescriptor<IndexedAlbumRecommendation>()),
            persistentBytes: persistentStoreBytes()
        )
    }

    // MARK: - Writes

    func upsertTracks(
        _ songs: [Song],
        serverID: UUID,
        generation: String,
        serverOrderStart: Int?,
        preserveExistingGeneration: Bool = false
    ) throws {
        guard !removedServerIDs.contains(serverID), !songs.isEmpty else { return }
        let context = ModelContext(modelContainer)

        for (index, song) in songs.enumerated() {
            let key = Self.recordKey(serverID: serverID, itemID: song.id)
            let payload = try encoder.encode(song)
            let serverOrder = serverOrderStart.map { $0 + index }

            if preserveExistingGeneration,
               let existing = try trackRow(recordKey: key, in: context) {
                existing.title = song.title
                existing.albumName = song.album
                existing.artistName = song.artist
                existing.albumId = song.albumId
                existing.artistId = song.artistId
                existing.searchText = LibraryIndexText.searchText(song.title, song.artist, song.album)
                existing.sortTitle = LibraryIndexText.normalized(song.sortName ?? song.title)
                if let serverOrder { existing.serverOrder = serverOrder }
                existing.createdAt = song.created
                existing.payload = payload
                continue
            }

            context.insert(
                IndexedTrack(
                    recordKey: key,
                    serverId: serverID,
                    itemId: song.id,
                    title: song.title,
                    albumName: song.album,
                    artistName: song.artist,
                    albumId: song.albumId,
                    artistId: song.artistId,
                    searchText: LibraryIndexText.searchText(song.title, song.artist, song.album),
                    sortTitle: LibraryIndexText.normalized(song.sortName ?? song.title),
                    serverOrder: serverOrder,
                    createdAt: song.created,
                    generation: generation,
                    payload: payload
                )
            )
        }
        try context.save()
    }

    func upsertAlbums(
        _ albums: [AlbumID3],
        serverID: UUID,
        generation: String,
        preserveExistingGeneration: Bool = false
    ) throws {
        guard !removedServerIDs.contains(serverID), !albums.isEmpty else { return }
        let context = ModelContext(modelContainer)

        for album in albums {
            let key = Self.recordKey(serverID: serverID, itemID: album.id)
            let payload = try encoder.encode(album)

            if preserveExistingGeneration,
               let existing = try albumRow(recordKey: key, in: context) {
                existing.name = album.name
                existing.artistName = album.artist
                existing.artistId = album.artistId
                existing.searchText = LibraryIndexText.searchText(album.name, album.artist)
                existing.sortName = LibraryIndexText.normalized(album.sortName ?? album.name)
                existing.createdAt = album.created
                existing.payload = payload
                continue
            }

            context.insert(
                IndexedAlbum(
                    recordKey: key,
                    serverId: serverID,
                    itemId: album.id,
                    name: album.name,
                    artistName: album.artist,
                    artistId: album.artistId,
                    searchText: LibraryIndexText.searchText(album.name, album.artist),
                    sortName: LibraryIndexText.normalized(album.sortName ?? album.name),
                    createdAt: album.created,
                    generation: generation,
                    payload: payload
                )
            )
        }
        try context.save()
    }

    func upsertArtists(
        _ indexedArtists: [(indexName: String, artist: ArtistID3)],
        serverID: UUID,
        generation: String,
        preserveExistingGeneration: Bool = false
    ) throws {
        guard !removedServerIDs.contains(serverID), !indexedArtists.isEmpty else { return }
        let context = ModelContext(modelContainer)

        for indexedArtist in indexedArtists {
            let artist = indexedArtist.artist
            let key = Self.recordKey(serverID: serverID, itemID: artist.id)
            let payload = try encoder.encode(artist)

            if preserveExistingGeneration,
               let existing = try artistRow(recordKey: key, in: context) {
                existing.name = artist.name
                existing.normalizedName = LibraryIndexText.normalized(artist.name)
                existing.indexName = indexedArtist.indexName
                existing.searchText = LibraryIndexText.searchText(artist.name)
                existing.sortName = LibraryIndexText.normalized(artist.sortName ?? artist.name)
                existing.payload = payload
                continue
            }

            context.insert(
                IndexedArtist(
                    recordKey: key,
                    serverId: serverID,
                    itemId: artist.id,
                    name: artist.name,
                    normalizedName: LibraryIndexText.normalized(artist.name),
                    indexName: indexedArtist.indexName,
                    searchText: LibraryIndexText.searchText(artist.name),
                    sortName: LibraryIndexText.normalized(artist.sortName ?? artist.name),
                    generation: generation,
                    payload: payload
                )
            )
        }
        try context.save()
    }

    func upsertPlaylists(
        _ playlists: [Playlist],
        serverID: UUID,
        generation: String
    ) throws {
        guard !removedServerIDs.contains(serverID), !playlists.isEmpty else { return }
        let context = ModelContext(modelContainer)

        for (serverOrder, playlist) in playlists.enumerated() {
            let key = Self.recordKey(serverID: serverID, itemID: playlist.id)
            let payload = try encoder.encode(IndexedPlaylistPayload(playlist))
            if let existing = try playlistRow(recordKey: key, in: context) {
                existing.name = playlist.name
                existing.sortName = LibraryIndexText.normalized(playlist.name)
                existing.serverOrder = serverOrder
                existing.generation = generation
                existing.summaryPayload = payload
            } else {
                context.insert(
                    IndexedPlaylist(
                        recordKey: key,
                        serverId: serverID,
                        itemId: playlist.id,
                        name: playlist.name,
                        sortName: LibraryIndexText.normalized(playlist.name),
                        serverOrder: serverOrder,
                        generation: generation,
                        summaryPayload: payload
                    )
                )
            }
        }
        try context.save()
    }

    func cachePlaylistDetail(_ playlist: PlaylistWithSongs, serverID: UUID) throws {
        guard !removedServerIDs.contains(serverID) else { return }
        let context = ModelContext(modelContainer)
        let key = Self.recordKey(serverID: serverID, itemID: playlist.id)
        let detail = IndexedPlaylistPayload(playlist)
        let summaryPayload = try encoder.encode(IndexedPlaylistPayload(detail.summary))
        let detailPayload = try encoder.encode(detail)

        if let existing = try playlistRow(recordKey: key, in: context) {
            existing.name = playlist.name
            existing.sortName = LibraryIndexText.normalized(playlist.name)
            existing.summaryPayload = summaryPayload
            existing.detailPayload = detailPayload
            existing.detailSummaryPayload = summaryPayload
        } else {
            context.insert(
                IndexedPlaylist(
                    recordKey: key,
                    serverId: serverID,
                    itemId: playlist.id,
                    name: playlist.name,
                    sortName: LibraryIndexText.normalized(playlist.name),
                    serverOrder: .max,
                    generation: "opportunistic",
                    summaryPayload: summaryPayload,
                    detailPayload: detailPayload,
                    detailSummaryPayload: summaryPayload
                )
            )
        }
        try context.save()
    }

    func cachePlaylistSummary(_ playlist: Playlist, serverID: UUID) throws {
        guard !removedServerIDs.contains(serverID) else { return }
        let context = ModelContext(modelContainer)
        let key = Self.recordKey(serverID: serverID, itemID: playlist.id)
        let summaryPayload = try encoder.encode(IndexedPlaylistPayload(playlist))

        if let existing = try playlistRow(recordKey: key, in: context) {
            existing.name = playlist.name
            existing.sortName = LibraryIndexText.normalized(playlist.name)
            existing.summaryPayload = summaryPayload
        } else {
            context.insert(
                IndexedPlaylist(
                    recordKey: key,
                    serverId: serverID,
                    itemId: playlist.id,
                    name: playlist.name,
                    sortName: LibraryIndexText.normalized(playlist.name),
                    serverOrder: .max,
                    generation: "opportunistic",
                    summaryPayload: summaryPayload
                )
            )
        }
        try context.save()
    }

    func cacheAlbumRecommendations(
        _ albums: [AlbumID3],
        sourceAlbumID: String,
        serverID: UUID,
        requestedLimit: Int,
        refreshedAt: Date = .now
    ) throws {
        guard !removedServerIDs.contains(serverID) else { return }
        let context = ModelContext(modelContainer)
        let key = Self.recordKey(serverID: serverID, itemID: sourceAlbumID)
        let payload = try encoder.encode(albums)

        if let existing = try albumRecommendationRow(recordKey: key, in: context) {
            existing.refreshedAt = refreshedAt
            existing.requestedLimit = requestedLimit
            existing.payload = payload
        } else {
            context.insert(
                IndexedAlbumRecommendation(
                    recordKey: key,
                    serverId: serverID,
                    sourceAlbumId: sourceAlbumID,
                    refreshedAt: refreshedAt,
                    requestedLimit: requestedLimit,
                    payload: payload
                )
            )
        }
        try context.save()
    }

    func removePlaylist(id: String, serverID: UUID) throws {
        let context = ModelContext(modelContainer)
        let key = Self.recordKey(serverID: serverID, itemID: id)
        if let row = try playlistRow(recordKey: key, in: context) {
            context.delete(row)
            try context.save()
        }
    }

    func markPlaylistsIncomplete(serverID: UUID) throws {
        let context = ModelContext(modelContainer)
        if let state = try playlistState(for: serverID, in: context) {
            state.syncedAt = nil
            try context.save()
        }
    }

    func complete(
        _ kind: LibraryIndexKind,
        serverID: UUID,
        generation: String,
        syncedAt: Date = .now
    ) throws {
        guard !removedServerIDs.contains(serverID) else { return }
        let context = ModelContext(modelContainer)
        let sid = serverID
        let completedGeneration = generation

        switch kind {
        case .artists:
            try context.delete(
                model: IndexedArtist.self,
                where: #Predicate { $0.serverId == sid && $0.generation != completedGeneration }
            )
        case .albums:
            try context.delete(
                model: IndexedAlbum.self,
                where: #Predicate { $0.serverId == sid && $0.generation != completedGeneration }
            )
        case .tracks:
            try context.delete(
                model: IndexedTrack.self,
                where: #Predicate { $0.serverId == sid && $0.generation != completedGeneration }
            )
        case .playlists:
            try context.delete(
                model: IndexedPlaylist.self,
                where: #Predicate { $0.serverId == sid && $0.generation != completedGeneration }
            )
        }

        if kind == .playlists {
            let indexState = try playlistState(for: serverID, in: context) ?? {
                let newState = PlaylistIndexState(serverId: serverID)
                context.insert(newState)
                return newState
            }()
            indexState.syncedAt = syncedAt
            try context.save()
            return
        }

        let indexState = try state(for: serverID, in: context) ?? {
            let newState = LibraryIndexState(serverId: serverID)
            context.insert(newState)
            return newState
        }()
        switch kind {
        case .artists: indexState.artistsSyncedAt = syncedAt
        case .albums: indexState.albumsSyncedAt = syncedAt
        case .tracks: indexState.tracksSyncedAt = syncedAt
        case .playlists: break
        }
        try context.save()
    }

    func removeServer(_ serverID: UUID) throws {
        removedServerIDs.insert(serverID)
        try purge(serverID)
    }

    /// Removes the complete discardable library index while preserving the app's main SwiftData store.
    func eraseAll() throws {
        removedServerIDs.removeAll()
        try modelContainer.erase()
    }

    /// Clears metadata after a server endpoint or account changes while allowing
    /// the stable configuration ID to be indexed again.
    func resetServer(_ serverID: UUID) throws {
        removedServerIDs.remove(serverID)
        try purge(serverID)
    }

    private func purge(_ serverID: UUID) throws {
        let context = ModelContext(modelContainer)
        let sid = serverID
        try context.delete(model: IndexedTrack.self, where: #Predicate { $0.serverId == sid })
        try context.delete(model: IndexedAlbum.self, where: #Predicate { $0.serverId == sid })
        try context.delete(model: IndexedArtist.self, where: #Predicate { $0.serverId == sid })
        try context.delete(model: IndexedPlaylist.self, where: #Predicate { $0.serverId == sid })
        try context.delete(model: IndexedAlbumRecommendation.self, where: #Predicate { $0.serverId == sid })
        try context.delete(model: LibraryIndexState.self, where: #Predicate { $0.serverId == sid })
        try context.delete(model: PlaylistIndexState.self, where: #Predicate { $0.serverId == sid })
        try context.save()
    }

    // MARK: - Reads

    func albumRecommendations(sourceAlbumID: String, serverID: UUID) throws -> CachedAlbumRecommendations? {
        let context = ModelContext(modelContainer)
        let key = Self.recordKey(serverID: serverID, itemID: sourceAlbumID)
        guard let row = try albumRecommendationRow(recordKey: key, in: context) else { return nil }
        return CachedAlbumRecommendations(
            albums: try decoder.decode([AlbumID3].self, from: row.payload),
            refreshedAt: row.refreshedAt,
            requestedLimit: row.requestedLimit
        )
    }

    func freshRecommendationAlbumIDs(
        serverID: UUID,
        refreshedAfter cutoff: Date,
        minimumRequestedLimit: Int
    ) throws -> Set<String> {
        let context = ModelContext(modelContainer)
        let sid = serverID
        let limit = minimumRequestedLimit
        let descriptor = FetchDescriptor<IndexedAlbumRecommendation>(
            predicate: #Predicate {
                $0.serverId == sid && $0.refreshedAt >= cutoff && $0.requestedLimit >= limit
            }
        )
        return Set(try context.fetch(descriptor).map(\.sourceAlbumId))
    }

    func search(_ query: String, serverID: UUID) throws -> LibraryIndexSearchResults {
        let context = ModelContext(modelContainer)
        let sid = serverID
        let term = LibraryIndexText.normalized(query)

        var artistDescriptor = FetchDescriptor<IndexedArtist>(
            predicate: #Predicate {
                $0.serverId == sid && $0.searchText.localizedStandardContains(term)
            },
            sortBy: [SortDescriptor(\.sortName)]
        )
        artistDescriptor.fetchLimit = 50

        var albumDescriptor = FetchDescriptor<IndexedAlbum>(
            predicate: #Predicate {
                $0.serverId == sid && $0.searchText.localizedStandardContains(term)
            },
            sortBy: [SortDescriptor(\.sortName)]
        )
        albumDescriptor.fetchLimit = 100

        var trackDescriptor = FetchDescriptor<IndexedTrack>(
            predicate: #Predicate {
                $0.serverId == sid && $0.searchText.localizedStandardContains(term)
            },
            sortBy: [SortDescriptor(\.sortTitle)]
        )
        trackDescriptor.fetchLimit = 200

        return LibraryIndexSearchResults(
            artists: try context.fetch(artistDescriptor).compactMap(decodeArtist),
            albums: try context.fetch(albumDescriptor).compactMap(decodeAlbum),
            songs: try context.fetch(trackDescriptor).compactMap(decodeSong)
        )
    }

    func artists(serverID: UUID) throws -> [ArtistIndex] {
        let context = ModelContext(modelContainer)
        let sid = serverID
        let descriptor = FetchDescriptor<IndexedArtist>(
            predicate: #Predicate { $0.serverId == sid },
            sortBy: [SortDescriptor(\.indexName), SortDescriptor(\.sortName)]
        )
        let rows = try context.fetch(descriptor)
        var order: [String] = []
        var grouped: [String: [ArtistID3]] = [:]
        for row in rows {
            guard let artist = decodeArtist(row) else { continue }
            if grouped[row.indexName] == nil { order.append(row.indexName) }
            grouped[row.indexName, default: []].append(artist)
        }
        return order.map { ArtistIndex(name: $0, artist: grouped[$0] ?? []) }
    }

    func artist(id: String, serverID: UUID) throws -> ArtistID3? {
        let context = ModelContext(modelContainer)
        let key = Self.recordKey(serverID: serverID, itemID: id)
        guard let row = try artistRow(recordKey: key, in: context),
              let base = decodeArtist(row) else { return nil }
        let albums = try albums(artistID: id, serverID: serverID, in: context)
        return Self.artist(base, replacingAlbums: albums.isEmpty ? base.album : albums)
    }

    func artist(named normalizedName: String, serverID: UUID) throws -> ArtistID3? {
        let context = ModelContext(modelContainer)
        let sid = serverID
        let name = LibraryIndexText.normalized(normalizedName)
        var descriptor = FetchDescriptor<IndexedArtist>(
            predicate: #Predicate { $0.serverId == sid && $0.normalizedName == name },
            sortBy: [SortDescriptor(\.sortName)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first.flatMap(decodeArtist)
    }

    func albums(serverID: UUID) throws -> [AlbumID3] {
        let context = ModelContext(modelContainer)
        let sid = serverID
        let descriptor = FetchDescriptor<IndexedAlbum>(
            predicate: #Predicate { $0.serverId == sid },
            sortBy: [SortDescriptor(\.sortName)]
        )
        return try context.fetch(descriptor).compactMap(decodeAlbum)
    }

    func recentlyAddedAlbums(serverID: UUID, limit: Int) throws -> [AlbumID3] {
        let context = ModelContext(modelContainer)
        let sid = serverID
        var descriptor = FetchDescriptor<IndexedAlbum>(
            predicate: #Predicate { $0.serverId == sid },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse), SortDescriptor(\.sortName)]
        )
        descriptor.fetchLimit = limit
        return try context.fetch(descriptor).compactMap(decodeAlbum)
    }

    func album(id: String, serverID: UUID) throws -> AlbumID3? {
        let context = ModelContext(modelContainer)
        let key = Self.recordKey(serverID: serverID, itemID: id)
        guard let row = try albumRow(recordKey: key, in: context),
              let base = decodeAlbum(row) else { return nil }
        let songs = try songs(albumID: id, serverID: serverID, in: context)
        return Self.album(base, replacingSongs: songs.isEmpty ? base.song : songs)
    }

    func songs(serverID: UUID, offset: Int, count: Int) throws -> [Song] {
        let context = ModelContext(modelContainer)
        let sid = serverID
        var descriptor = FetchDescriptor<IndexedTrack>(
            predicate: #Predicate { $0.serverId == sid && $0.serverOrder != nil },
            sortBy: [SortDescriptor(\.serverOrder)]
        )
        descriptor.fetchOffset = offset
        descriptor.fetchLimit = count
        return try context.fetch(descriptor).compactMap(decodeSong)
    }

    func songs(artistID: String, serverID: UUID) throws -> [Song] {
        let context = ModelContext(modelContainer)
        return try songs(artistID: artistID, serverID: serverID, in: context)
    }

    func playlists(serverID: UUID) throws -> [Playlist] {
        let context = ModelContext(modelContainer)
        let sid = serverID
        let descriptor = FetchDescriptor<IndexedPlaylist>(
            predicate: #Predicate { $0.serverId == sid },
            sortBy: [SortDescriptor(\.serverOrder), SortDescriptor(\.sortName)]
        )
        return try context.fetch(descriptor).compactMap(decodePlaylist)
    }

    func playlist(id: String, serverID: UUID) throws -> LibraryIndexedPlaylistDetail? {
        let context = ModelContext(modelContainer)
        let key = Self.recordKey(serverID: serverID, itemID: id)
        guard let row = try playlistRow(recordKey: key, in: context),
              let detailPayload = row.detailPayload,
              let playlist = decodePlaylistDetail(detailPayload, id: row.itemId) else { return nil }
        return LibraryIndexedPlaylistDetail(
            playlist: playlist,
            isCurrent: row.detailSummaryPayload == row.summaryPayload
        )
    }

    // MARK: - Model lookup

    private func state(for serverID: UUID, in context: ModelContext) throws -> LibraryIndexState? {
        let sid = serverID
        var descriptor = FetchDescriptor<LibraryIndexState>(
            predicate: #Predicate { $0.serverId == sid }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func playlistState(for serverID: UUID, in context: ModelContext) throws -> PlaylistIndexState? {
        let sid = serverID
        var descriptor = FetchDescriptor<PlaylistIndexState>(
            predicate: #Predicate { $0.serverId == sid }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func trackRow(recordKey: String, in context: ModelContext) throws -> IndexedTrack? {
        let key = recordKey
        var descriptor = FetchDescriptor<IndexedTrack>(predicate: #Predicate { $0.recordKey == key })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func albumRow(recordKey: String, in context: ModelContext) throws -> IndexedAlbum? {
        let key = recordKey
        var descriptor = FetchDescriptor<IndexedAlbum>(predicate: #Predicate { $0.recordKey == key })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func artistRow(recordKey: String, in context: ModelContext) throws -> IndexedArtist? {
        let key = recordKey
        var descriptor = FetchDescriptor<IndexedArtist>(predicate: #Predicate { $0.recordKey == key })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func playlistRow(recordKey: String, in context: ModelContext) throws -> IndexedPlaylist? {
        let key = recordKey
        var descriptor = FetchDescriptor<IndexedPlaylist>(predicate: #Predicate { $0.recordKey == key })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func albumRecommendationRow(
        recordKey: String,
        in context: ModelContext
    ) throws -> IndexedAlbumRecommendation? {
        let key = recordKey
        var descriptor = FetchDescriptor<IndexedAlbumRecommendation>(
            predicate: #Predicate { $0.recordKey == key }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func persistentStoreBytes() -> Int64 {
        modelContainer.configurations.reduce(into: 0) { total, configuration in
            let path = configuration.url.path
            for candidate in [path, "\(path)-wal", "\(path)-shm"] {
                let attributes = try? FileManager.default.attributesOfItem(atPath: candidate)
                total += (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            }
        }
    }

    private func albums(artistID: String, serverID: UUID, in context: ModelContext) throws -> [AlbumID3] {
        let sid = serverID
        let aid: String? = artistID
        let descriptor = FetchDescriptor<IndexedAlbum>(
            predicate: #Predicate { $0.serverId == sid && $0.artistId == aid },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse), SortDescriptor(\.sortName)]
        )
        return try context.fetch(descriptor).compactMap(decodeAlbum)
    }

    private func songs(albumID: String, serverID: UUID, in context: ModelContext) throws -> [Song] {
        let sid = serverID
        let targetAlbumID: String? = albumID
        let descriptor = FetchDescriptor<IndexedTrack>(
            predicate: #Predicate { $0.serverId == sid && $0.albumId == targetAlbumID }
        )
        return try context.fetch(descriptor)
            .compactMap(decodeSong)
            .sorted(by: Self.albumTrackOrder)
    }

    private func songs(artistID: String, serverID: UUID, in context: ModelContext) throws -> [Song] {
        let sid = serverID
        let targetArtistID: String? = artistID
        let descriptor = FetchDescriptor<IndexedTrack>(
            predicate: #Predicate { $0.serverId == sid && $0.artistId == targetArtistID }
        )
        return try context.fetch(descriptor)
            .compactMap(decodeSong)
            .sorted(by: Self.artistTrackOrder)
    }

    // MARK: - Payload conversion

    private func decodeSong(_ row: IndexedTrack) -> Song? {
        do {
            return try decoder.decode(Song.self, from: row.payload)
        } catch {
            Logger.library.error("Library index: invalid track payload id=\(row.itemId, privacy: .public)")
            return nil
        }
    }

    private func decodeAlbum(_ row: IndexedAlbum) -> AlbumID3? {
        do {
            return try decoder.decode(AlbumID3.self, from: row.payload)
        } catch {
            Logger.library.error("Library index: invalid album payload id=\(row.itemId, privacy: .public)")
            return nil
        }
    }

    private func decodeArtist(_ row: IndexedArtist) -> ArtistID3? {
        do {
            return try decoder.decode(ArtistID3.self, from: row.payload)
        } catch {
            Logger.library.error("Library index: invalid artist payload id=\(row.itemId, privacy: .public)")
            return nil
        }
    }

    private func decodePlaylist(_ row: IndexedPlaylist) -> Playlist? {
        do {
            return try decoder.decode(IndexedPlaylistPayload.self, from: row.summaryPayload).summary
        } catch {
            Logger.library.error("Library index: invalid playlist payload id=\(row.itemId, privacy: .public)")
            return nil
        }
    }

    private func decodePlaylistDetail(_ payload: Data, id: String) -> PlaylistWithSongs? {
        do {
            return try decoder.decode(IndexedPlaylistPayload.self, from: payload).detail
        } catch {
            Logger.library.error("Library index: invalid playlist detail payload id=\(id, privacy: .public)")
            return nil
        }
    }

    private static func recordKey(serverID: UUID, itemID: String) -> String {
        "\(serverID.uuidString)|\(itemID)"
    }

    private static func albumTrackOrder(_ lhs: Song, _ rhs: Song) -> Bool {
        let lhsKey = (lhs.discNumber ?? 1, lhs.track ?? Int.max, LibraryIndexText.normalized(lhs.title))
        let rhsKey = (rhs.discNumber ?? 1, rhs.track ?? Int.max, LibraryIndexText.normalized(rhs.title))
        return lhsKey < rhsKey
    }

    private static func artistTrackOrder(_ lhs: Song, _ rhs: Song) -> Bool {
        if lhs.year != rhs.year {
            return (lhs.year ?? Int.min) > (rhs.year ?? Int.min)
        }
        let lhsKey = (LibraryIndexText.normalized(lhs.album ?? ""), lhs.discNumber ?? 1, lhs.track ?? Int.max)
        let rhsKey = (LibraryIndexText.normalized(rhs.album ?? ""), rhs.discNumber ?? 1, rhs.track ?? Int.max)
        return lhsKey < rhsKey
    }

    private static func album(_ album: AlbumID3, replacingSongs songs: [Song]?) -> AlbumID3 {
        AlbumID3(
            id: album.id,
            name: album.name,
            songCount: album.songCount,
            duration: album.duration,
            artist: album.artist,
            artistId: album.artistId,
            coverArt: album.coverArt,
            playCount: album.playCount,
            created: album.created,
            starred: album.starred,
            year: album.year,
            genre: album.genre,
            played: album.played,
            userRating: album.userRating,
            musicBrainzId: album.musicBrainzId,
            genres: album.genres,
            artists: album.artists,
            displayArtist: album.displayArtist,
            releaseTypes: album.releaseTypes,
            moods: album.moods,
            sortName: album.sortName,
            originalReleaseDate: album.originalReleaseDate,
            releaseDate: album.releaseDate,
            isCompilation: album.isCompilation,
            discTitles: album.discTitles,
            recordLabels: album.recordLabels,
            explicitStatus: album.explicitStatus,
            version: album.version,
            song: songs
        )
    }

    private static func artist(_ artist: ArtistID3, replacingAlbums albums: [AlbumID3]?) -> ArtistID3 {
        ArtistID3(
            id: artist.id,
            name: artist.name,
            albumCount: artist.albumCount,
            coverArt: artist.coverArt,
            starred: artist.starred,
            userRating: artist.userRating,
            musicBrainzId: artist.musicBrainzId,
            sortName: artist.sortName,
            roles: artist.roles,
            album: albums
        )
    }
}
