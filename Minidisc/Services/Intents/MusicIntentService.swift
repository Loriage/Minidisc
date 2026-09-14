import Foundation
import SwiftSonic

@MainActor
struct MusicIntentService {
    let container: AppContainer

    private struct Context {
        let server: ServerSnapshot
        let scope: String
        let version: ServerConnection.Version?
    }

    private func context() throws -> Context {
        guard let server = container.serverState.activeServer else { throw MusicIntentError.noServer }
        return Context(server: server,
                       scope: MusicIntentID.scope(baseURL: server.baseURL, username: server.username),
                       version: container.serverState.activeConnectionVersion)
    }

    private func validate(_ context: Context) throws {
        try Task.checkCancellation()
        let current = try self.context()
        guard current.scope == context.scope, current.version == context.version else {
            throw MusicIntentError.differentServer
        }
    }

    func search(_ text: String) async throws -> [MusicIntentRecord] {
        container.playbackDiagnostics.record(.musicIntent(.searchStarted))
        let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return try await suggestions() }
        let context = try context()
        let library = container.libraryService
        async let music = Self.attempt { try await library.search(term) }
        async let playlists = Self.attempt { try await library.playlists() }
        let (musicResult, playlistResult) = await (music, playlists)
        try validate(context)
        var records: [MusicIntentRecord] = []
        if case .success(let matches) = musicResult {
            records += (matches.artist ?? []).map { MusicIntentRecord(scope: context.scope, artist: $0) }
            records += (matches.album ?? []).map { MusicIntentRecord(scope: context.scope, album: $0) }
            records += (matches.song ?? []).map { MusicIntentRecord(scope: context.scope, song: $0) }
        }
        if case .success(let matches) = playlistResult {
            records += matches.filter { Self.matchesPlaylist($0.name, term: term) }
                .map { MusicIntentRecord(scope: context.scope, playlist: $0) }
        }
        if records.isEmpty, case .failure = musicResult, case .failure = playlistResult {
            throw MusicIntentError.unavailable
        }
        let results = Array(records.sorted {
            let lhs = Self.matchRank($0.title, term: term)
            let rhs = Self.matchRank($1.title, term: term)
            return lhs == rhs ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : lhs < rhs
        }.prefix(50))
        container.playbackDiagnostics.record(.musicIntent(.searchCompleted(count: results.count)))
        return results
    }

    nonisolated static func matchRank(_ title: String, term: String) -> Int {
        let title = LibraryIndexText.normalized(title)
        let term = LibraryIndexText.normalized(term)
        return title == term ? 0 : title.hasPrefix(term) ? 1 : 2
    }

    func searchPlaylists(_ text: String) async throws -> [MusicIntentRecord] {
        container.playbackDiagnostics.record(.musicIntent(.searchStarted))
        let context = try context()
        let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let playlists: [Playlist]
        do { playlists = try await container.libraryService.playlists() }
        catch {
            try validate(context)
            throw MusicIntentError.unavailable
        }
        try validate(context)
        let records = playlists.filter { term.isEmpty || Self.matchesPlaylist($0.name, term: term) }
            .map { MusicIntentRecord(scope: context.scope, playlist: $0) }
            .sorted {
                let lhs = Self.matchRank($0.title, term: term)
                let rhs = Self.matchRank($1.title, term: term)
                return lhs == rhs ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : lhs < rhs
            }
        container.playbackDiagnostics.record(.musicIntent(.searchCompleted(count: records.count)))
        return Array(records.prefix(50))
    }

    nonisolated static func matchesPlaylist(_ name: String, term: String) -> Bool {
        if name.localizedStandardContains(term) { return true }
        return Mood.allCases.contains {
            $0.playlistName == name && String(localized: $0.title).localizedStandardContains(term)
        }
    }

    func suggestions() async throws -> [MusicIntentRecord] {
        guard container.serverState.activeServer != nil else { return [] }
        let context = try context()
        // Parameter pickers must not initiate a full library walk.
        let albums = try await container.libraryIndexStore.recentlyAddedAlbums(serverID: context.server.id, limit: 12)
        let playlists = try await container.libraryIndexStore.playlists(serverID: context.server.id)
        let songs = try await container.libraryIndexStore.songs(serverID: context.server.id, offset: 0, count: 8)
        try validate(context)
        return Array(playlists.prefix(12).map { MusicIntentRecord(scope: context.scope, playlist: $0) }
                     + albums.map { MusicIntentRecord(scope: context.scope, album: $0) }
                     + songs.map { MusicIntentRecord(scope: context.scope, song: $0) })
    }

    func resolve(_ identifiers: [String]) async throws -> [MusicIntentRecord] {
        guard !identifiers.isEmpty else { return [] }
        let context = try context()
        let references = identifiers.compactMap(MusicIntentID.init(rawValue:))
        guard references.allSatisfy({ $0.scope == context.scope }) else { throw MusicIntentError.differentServer }
        var records = try await container.libraryIndexStore.intentRecords(
            references: references, serverID: context.server.id, scope: context.scope)
        let found = Set(records.map(\.id))
        let missing = references.filter { !found.contains($0.rawValue) }
        if !missing.isEmpty, container.serverState.isOnline {
            let connection = try await container.serverService.activeConnection()
            try validate(context)
            // Resolve a lost index without scanning the library. At most four requests run at once.
            for start in stride(from: 0, to: missing.count, by: 4) {
                try validate(context)
                let batch = Array(missing[start..<min(start + 4, missing.count)])
                let recovered = try await withThrowingTaskGroup(of: MusicIntentRecord?.self) { group in
                    for reference in batch {
                        group.addTask { try await Self.fetch(reference, connection: connection) }
                    }
                    var result: [MusicIntentRecord] = []
                    for try await record in group { if let record { result.append(record) } }
                    return result
                }
                records += recovered
            }
        }
        try validate(context)
        let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return identifiers.compactMap { byID[$0] }
    }

    private nonisolated static func fetch(_ reference: MusicIntentID, connection: ServerConnection) async throws -> MusicIntentRecord? {
        let client = connection.makeSwiftSonicClient(requestTimeout: 10, retryPolicy: .default)
        do {
            switch reference.kind {
            case .song: return try await MusicIntentRecord(scope: reference.scope, song: client.getSong(id: reference.resourceID))
            case .album: return try await MusicIntentRecord(scope: reference.scope, album: client.getAlbum(id: reference.resourceID))
            case .artist: return try await MusicIntentRecord(scope: reference.scope, artist: client.getArtist(id: reference.resourceID))
            case .playlist:
                let playlists = try await client.getPlaylists(username: nil)
                return playlists.first(where: { $0.id == reference.resourceID }).map {
                    MusicIntentRecord(scope: reference.scope, playlist: $0)
                }
            }
        } catch let error as SwiftSonicError {
            if case .api(let apiError) = error, apiError.code == .notFound { return nil }
            throw MusicIntentError.unavailable
        }
    }

    func play(id: String, shuffle: Bool = false, repeatMode: RepeatMode? = nil) async throws {
        container.playbackDiagnostics.record(.musicIntent(.selectionPlayback))
        let context = try context()
        guard let reference = MusicIntentID(rawValue: id), reference.scope == context.scope else {
            throw MusicIntentError.differentServer
        }
        // Register the Play intent before fetching, so Pause/Next or a newer request wins.
        try await container.playerService.play(preparingQueue: {
            let tracks = try await self.tracks(reference, context: context)
            try await self.validate(context)
            guard !tracks.isEmpty else { throw MusicIntentError.empty }
            return PreparedPlaybackQueue(tracks: shuffle ? tracks.shuffled() : tracks, startIndex: 0, repeatMode: repeatMode)
        })
    }

    func enqueue(id: String, next: Bool, shuffle: Bool) async throws {
        let context = try context()
        guard let reference = MusicIntentID(rawValue: id), reference.scope == context.scope else {
            throw MusicIntentError.differentServer
        }
        let generation = container.playerState.queueGeneration
        let tracks = try await tracks(reference, context: context)
        try validate(context)
        guard generation == container.playerState.queueGeneration else { throw CancellationError() }
        guard !tracks.isEmpty else { throw MusicIntentError.empty }
        let ordered = shuffle ? tracks.shuffled() : tracks
        if next { await container.playerService.playNext(ordered) }
        else { await container.playerService.addToQueue(ordered) }
    }

    func play(mood: Mood) async throws {
        let context = try context()
        try await container.playerService.play(preparingQueue: {
            let reference = try await self.moodReference(mood, context: context)
            let tracks = try await self.tracks(reference, context: context)
            try await self.validate(context)
            guard !tracks.isEmpty else { throw MusicIntentError.empty }
            return PreparedPlaybackQueue(tracks: tracks, startIndex: 0)
        })
    }

    private func moodReference(_ mood: Mood, context: Context) async throws -> MusicIntentID {
        let service = container.moodPlaylistService
        let playlists: [MoodPlaylist]
        if container.serverState.isOnline {
            do { playlists = try await service.fetchPlaylists(serverId: context.server.id.uuidString) }
            catch is CancellationError { throw CancellationError() }
            catch { playlists = await service.cachedPlaylists(serverId: context.server.id.uuidString) }
        } else {
            playlists = await service.cachedPlaylists(serverId: context.server.id.uuidString)
        }
        try validate(context)
        guard let playlist = playlists.first(where: { $0.mood == mood }) else { throw MusicIntentError.moodUnavailable }
        return MusicIntentID(scope: context.scope, kind: .playlist, resourceID: playlist.id)
    }

    private func tracks(_ reference: MusicIntentID, context: Context) async throws -> [DisplayableSong] {
        try validate(context)
        let library = container.libraryService
        if !container.serverState.isOnline, let local = await localTracks(reference, context: context), !local.isEmpty {
            return local
        }
        do {
            switch reference.kind {
            case .song:
                return try await resolve([reference.rawValue]).compactMap(\.song)
            case .album:
                return try await (library.album(id: reference.resourceID).song ?? []).map { DisplayableSong(from: $0) }
            case .artist:
                return try await library.fetchAllTracks(forArtistID: reference.resourceID)
            case .playlist:
                return try await (library.playlist(id: reference.resourceID).entry ?? []).map { DisplayableSong(from: $0) }
            }
        } catch is CancellationError { throw CancellationError() }
        catch {
            try validate(context)
            if let local = await localTracks(reference, context: context), !local.isEmpty { return local }
            if let error = error as? MusicIntentError { throw error }
            throw MusicIntentError.unavailable
        }
    }

    private func localTracks(_ reference: MusicIntentID, context: Context) async -> [DisplayableSong]? {
        let downloads = container.downloadService
        switch reference.kind {
        case .song: return nil // The indexed song is resolved to its downloaded/cached source by the player.
        case .album: return await downloads.localAlbumData(albumId: reference.resourceID, serverId: context.server.id)?.songs
        case .artist: return await downloads.localArtistData(artistId: reference.resourceID, artistName: nil, serverId: context.server.id)?.tracks
        case .playlist: return await downloads.localPlaylistData(playlistId: reference.resourceID, serverId: context.server.id)?.songs
        }
    }

    private nonisolated static func attempt<T: Sendable>(_ operation: @Sendable () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await operation()) }
        catch { return .failure(error) }
    }
}
