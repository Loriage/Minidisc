import Foundation
import SwiftData
import SwiftSonic
import OSLog

actor PlaylistService: PlaylistServiceProtocol {
    private let serverService: any ServerServiceProtocol
    private let modelContainer: ModelContainer
    private let downloadService: any DownloadServiceProtocol
    private let libraryCatalog: LibraryCatalog
    private let clientFactory: @Sendable (ServerConnection) -> SwiftSonicClient
    private var mutations: [String: [CheckedContinuation<Void, Never>]] = [:]

    init(serverService: any ServerServiceProtocol, modelContainer: ModelContainer,
         downloadService: any DownloadServiceProtocol, libraryCatalog: LibraryCatalog,
         clientFactory: @escaping @Sendable (ServerConnection) -> SwiftSonicClient = { $0.makeSwiftSonicClient() }) {
        self.serverService = serverService
        self.modelContainer = modelContainer
        self.downloadService = downloadService
        self.libraryCatalog = libraryCatalog
        self.clientFactory = clientFactory
    }

    func listPlaylists() async throws -> [Playlist] { try await libraryCatalog.playlists() }
    func getPlaylist(id: String) async throws -> PlaylistWithSongs { try await libraryCatalog.refreshPlaylist(id: id) }

    @discardableResult
    func createPlaylist(name: String, description: String?) async throws -> PlaylistWithSongs {
        let connection = try await serverService.activeConnection()
        let client = clientFactory(connection)
        var result = try await client.createPlaylist(name: name)
        if let description, !description.isEmpty {
            try await client.updatePlaylist(id: result.id, comment: description)
            result = copying(result, comment: description)
        }
        await record(result, serverID: connection.version.serverID)
        return result
    }

    func deletePlaylist(id: String, purgeDownloads: Bool) async throws {
        let connection = try await serverService.activeConnection()
        let key = mutationKey(id, connection)
        await acquire(key)
        defer { release(key) }
        try await validate(connection)
        do { try await clientFactory(connection).deletePlaylist(id: id) }
        catch {
            // A proxy's HTTP 404 cannot establish that this playlist is absent.
            guard let sonic = error as? SwiftSonicError,
                  case .api(let detail) = sonic, detail.code == .notFound else { throw error }
        }
        let serverID = connection.version.serverID
        if purgeDownloads {
            try await downloadService.remove(playlistId: id, serverId: serverID)
            await MainActor.run {
                PlaylistCoverStore(modelContainer: modelContainer).remove(playlistId: id, serverId: serverID)
            }
        }
        await libraryCatalog.recordPlaylistMutation(summary: nil, detail: nil, deletedID: id, serverID: serverID)
    }

    func renamePlaylist(id: String, newName: String) async throws {
        try await mutate(id) { client, original in
            try await client.updatePlaylist(id: id, name: newName)
            return self.copying(original, name: newName)
        }
    }

    func updateDescription(id: String, description: String) async throws {
        try await mutate(id) { client, original in
            try await client.updatePlaylist(id: id, comment: description)
            return self.copying(original, comment: description)
        }
    }

    func addTracks(playlistId: String, songs: [Song]) async throws {
        try await mutate(playlistId) { client, original in
            try await client.updatePlaylist(id: playlistId, songIdsToAdd: songs.map(\.id))
            return self.copying(original, entry: (original.entry ?? []) + songs)
        }
    }

    func removeTracks(playlistId: String, indices: [Int]) async throws {
        try await mutate(playlistId) { client, original in
            let entries = original.entry ?? []
            guard indices.allSatisfy({ entries.indices.contains($0) }) else { throw CancellationError() }
            let removed = Set(indices)
            try await client.updatePlaylist(id: playlistId, songIndexesToRemove: Array(removed).sorted())
            return self.copying(original, entry: entries.enumerated().filter { !removed.contains($0.offset) }.map(\.element))
        }
    }

    func reorderTracks(playlistId: String, orderedSongIds: [String]) async throws {
        try await mutate(playlistId) { client, _ in
            try await client.createPlaylist(playlistId: playlistId, songIds: orderedSongIds)
        }
    }

    /// Capture one connection for the whole operation. An actor alone does not serialize
    /// mutations across network suspensions; the per-playlist gate does.
    private func mutate(_ id: String,
                        operation: (SwiftSonicClient, PlaylistWithSongs) async throws -> PlaylistWithSongs) async throws {
        let connection = try await serverService.activeConnection()
        let key = mutationKey(id, connection)
        await acquire(key)
        defer { release(key) }
        try await validate(connection)
        let client = clientFactory(connection)
        let original = try await client.getPlaylist(id: id)
        try await validate(connection)
        let result = try await operation(client, original)
        await record(result, serverID: connection.version.serverID)
    }

    private func validate(_ connection: ServerConnection) async throws {
        try Task.checkCancellation()
        guard await serverService.activeConnectionVersion() == connection.version else { throw CancellationError() }
    }

    private func mutationKey(_ id: String, _ connection: ServerConnection) -> String {
        "\(connection.version.serverID):\(id)"
    }

    private func acquire(_ key: String) async {
        if mutations[key] == nil { mutations[key] = []; return }
        await withCheckedContinuation { mutations[key, default: []].append($0) }
    }

    private func release(_ key: String) {
        guard var waiting = mutations[key], !waiting.isEmpty else { mutations[key] = nil; return }
        let next = waiting.removeFirst()
        mutations[key] = waiting
        next.resume()
    }

    private func record(_ playlist: PlaylistWithSongs, serverID: UUID) async {
        // The remote write has succeeded. Never turn an index failure into a retry of an append.
        do {
            let downloaded = try await DownloadedPlaylistReconciler.reconcile(
                playlist, serverID: serverID, modelContainer: modelContainer)
            if downloaded {
                for song in playlist.entry ?? [] {
                    Task { [downloadService] in
                        try? await downloadService.download(song: song, serverId: serverID)
                    }
                }
            }
        } catch {
            Logger.playlist.error("Could not reconcile downloaded playlist: \(error)")
        }
        await libraryCatalog.recordPlaylistMutation(summary: nil, detail: playlist, serverID: serverID)
    }

    func retryMissingPlaylistDownloads() async {
        guard let connection = try? await serverService.activeConnection() else { return }
        let serverID = connection.version.serverID
        let records = await MainActor.run {
            let context = ModelContext(modelContainer)
            return ((try? context.fetch(FetchDescriptor<DownloadedPlaylist>(predicate: #Predicate { $0.serverId == serverID }))) ?? [])
                .map { (id: $0.playlistId, songIDs: $0.songIds) }
        }
        for record in records {
            let key = mutationKey(record.id, connection)
            await acquire(key)
            defer { release(key) }
            do {
                try await validate(connection)
                let downloaded = await downloadService.downloadedSongIds(serverId: serverID)
                let missing = Set(record.songIDs).subtracting(downloaded)
                guard !missing.isEmpty else { continue }
                let playlist = try await clientFactory(connection).getPlaylist(id: record.id)
                try await validate(connection)
                // Retry saved membership only. A server-side edit must not replace a
                // deliberately retained offline copy during startup recovery.
                for song in playlist.entry ?? [] where missing.contains(song.id) {
                    Task { [downloadService] in
                        try? await downloadService.download(song: song, serverId: serverID)
                    }
                }
            } catch {
                if UserFacingError.isCancellation(error) { return }
                Logger.playlist.warning("Could not retry playlist downloads: \(error)")
            }
        }
    }

    private func copying(_ p: PlaylistWithSongs, name: String? = nil,
                         comment: String? = nil, entry: [Song]? = nil) -> PlaylistWithSongs {
        PlaylistWithSongs(id: p.id, name: name ?? p.name, songCount: entry?.count ?? p.songCount,
                          duration: entry?.reduce(0) { $0 + ($1.duration ?? 0) } ?? p.duration,
                          comment: comment ?? p.comment, owner: p.owner, isPublic: p.isPublic,
                          created: p.created, changed: p.changed, coverArt: p.coverArt, entry: entry ?? p.entry)
    }
}

@MainActor
enum DownloadedPlaylistReconciler {
    /// Replaces ordered membership, including duplicates and an intentionally empty playlist.
    /// Audio stays on disk; collection removal remains the responsibility of DownloadService.
    @discardableResult
    static func reconcile(_ playlist: PlaylistWithSongs, serverID: UUID, modelContainer: ModelContainer) throws -> Bool {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let id = playlist.id
        guard let record = try context.fetch(FetchDescriptor<DownloadedPlaylist>(
            predicate: #Predicate { $0.serverId == serverID && $0.playlistId == id })).first else { return false }
        let downloaded = Set(try context.fetch(FetchDescriptor<DownloadedTrack>(
            predicate: #Predicate { $0.serverId == serverID })).map(\.songId))
        record.songIds = (playlist.entry ?? []).map(\.id)
        record.name = playlist.name
        record.comment = playlist.comment
        record.coverArtId = playlist.coverArt
        record.totalTracksCount = record.songIds.count
        record.tracksCount = record.songIds.filter { downloaded.contains($0) }.count
        try context.save()
        NotificationCenter.default.post(name: .minidiscOfflineLibraryChanged, object: nil)
        return true
    }
}
