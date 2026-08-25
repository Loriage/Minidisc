import Foundation
import OSLog
import SwiftData
import SwiftSonic

nonisolated enum LibraryIndexKind: String, Sendable {
    case artists
    case albums
    case tracks
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

nonisolated struct LibraryIndexCompletion: Sendable, Equatable {
    let artists: Bool
    let albums: Bool
    let tracks: Bool

    var isComplete: Bool { artists && albums && tracks }
}

nonisolated struct LibraryIndexCounts: Sendable, Equatable {
    let artists: Int
    let albums: Int
    let tracks: Int
}

nonisolated struct LibraryIndexSearchResults: Sendable {
    let artists: [ArtistID3]
    let albums: [AlbumID3]
    let songs: [Song]

    var isEmpty: Bool { artists.isEmpty && albums.isEmpty && songs.isEmpty }
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
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var removedServerIDs: Set<UUID> = []

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    // MARK: - State

    func completion(for serverID: UUID) throws -> LibraryIndexCompletion {
        let context = ModelContext(modelContainer)
        let state = try state(for: serverID, in: context)
        return LibraryIndexCompletion(
            artists: state?.artistsSyncedAt != nil,
            albums: state?.albumsSyncedAt != nil,
            tracks: state?.tracksSyncedAt != nil
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
            )
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

    func complete(_ kind: LibraryIndexKind, serverID: UUID, generation: String) throws {
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
        }

        let indexState = try state(for: serverID, in: context) ?? {
            let newState = LibraryIndexState(serverId: serverID)
            context.insert(newState)
            return newState
        }()
        let now = Date()
        switch kind {
        case .artists: indexState.artistsSyncedAt = now
        case .albums: indexState.albumsSyncedAt = now
        case .tracks: indexState.tracksSyncedAt = now
        }
        try context.save()
    }

    func removeServer(_ serverID: UUID) throws {
        removedServerIDs.insert(serverID)
        try purge(serverID)
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
        try context.delete(model: LibraryIndexState.self, where: #Predicate { $0.serverId == sid })
        try context.save()
    }

    // MARK: - Reads

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

    // MARK: - Model lookup

    private func state(for serverID: UUID, in context: ModelContext) throws -> LibraryIndexState? {
        let sid = serverID
        var descriptor = FetchDescriptor<LibraryIndexState>(
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
