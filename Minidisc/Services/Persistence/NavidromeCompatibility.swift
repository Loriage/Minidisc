import CryptoKit
import Foundation
import OSLog
import SwiftData
import SwiftSonic

/// Runs before publishing an activated connection, and before restoring playback
/// or background downloads at launch. Every step is idempotent: the completion
/// marker is written only after all stores have succeeded.
actor NavidromeCompatibility {
    typealias CapabilitiesProbe = @Sendable (ServerConnection) async throws -> ServerCapabilities
    private let modelContainer: ModelContainer
    private let sessionService: PlaybackSessionService
    private let indexStore: LibraryIndexStore
    private let defaults: LockedUserDefaults
    private let homeCache: HomeFeedCache
    private let coversDirectory: URL
    private let journalURL: URL
    private let probe: CapabilitiesProbe
    private var pending: [String: Task<Void, any Error>] = [:]

    @MainActor
    init(modelContainer: ModelContainer, sessionService: PlaybackSessionService,
         indexStore: LibraryIndexStore, defaults: UserDefaults = .standard,
         homeCache: HomeFeedCache = .shared,
         coversDirectory: URL = URL.documentsDirectory.appendingPathComponent("app.minidisc/coverarts"),
         journalURL: URL = URL.applicationSupportDirectory.appendingPathComponent("minidisc-downloads/queue.json"),
         probe: @escaping CapabilitiesProbe = NavidromeCompatibility.fetchCapabilities) {
        self.modelContainer = modelContainer
        self.sessionService = sessionService
        self.indexStore = indexStore
        self.defaults = LockedUserDefaults(defaults)
        self.homeCache = homeCache
        self.coversDirectory = coversDirectory
        self.journalURL = journalURL
        self.probe = probe
    }

    func prepare(_ connection: ServerConnection, restoringSession: Bool) async throws {
        let marker = Self.marker(for: connection)
        if !defaults.bool(forKey: marker) {
            if let task = pending[marker] {
                try await task.value
            } else {
                let task = Task { try await self.migrate(connection, marker: marker, restoringSession: restoringSession) }
                pending[marker] = task
                defer { pending[marker] = nil }
                try await task.value
            }
        }
    }

    private func migrate(_ connection: ServerConnection, marker: String, restoringSession: Bool) async throws {
        // A short, read-only probe must never prevent an offline launch. Custom proxy
        // headers are retained; no native Navidrome/Jellyfin login is needed.
        let capabilities: ServerCapabilities
        do {
            capabilities = try await probe(connection)
        } catch {
            Logger.server.debug("Navidrome compatibility check deferred until a later activation")
            return
        }
        guard NavidromeCanonicalID.isRequired(serverType: capabilities.serverType, version: capabilities.serverVersion) else { return }
        try Task.checkCancellation()
        let serverID = connection.server.id
        let staleIndex = try await indexStore.hasLegacyNavidromeIDs(serverID: serverID)
        try await Self.migrateRecords(modelContainer: modelContainer, serverID: serverID, coversDirectory: coversDirectory)
        if restoringSession { try await sessionService.migrateNavidromeIDs() }
        try Self.migrateDownloadJournal(at: journalURL, serverID: serverID)
        migratePreferences(serverID: serverID)
        if staleIndex { try await indexStore.resetServer(serverID) }
        if let home = await homeCache.load(serverID: serverID),
           try NavidromeCanonicalID.containsLegacyIDs(in: JSONEncoder().encode(home)) {
            try await homeCache.remove(serverID: serverID)
        }
        defaults.set(true, forKey: marker)
        Logger.server.info("Navidrome canonical ID migration completed; local audio retained")
    }

    nonisolated private static func fetchCapabilities(_ connection: ServerConnection) async throws -> ServerCapabilities {
        let client = SwiftSonicClient(
            configuration: ServerConfiguration(serverURL: connection.baseURL,
                username: connection.server.username, password: connection.credentials.password, requestTimeout: 3),
            transport: CustomHeadersTransport(headers: connection.credentials.customHeaders, timeout: 3),
            retryPolicy: .none
        )
        return try await client.loadCapabilities()
    }

    private nonisolated static func marker(for connection: ServerConnection) -> String {
        let identity = connection.server.baseURL + "\u{0}" + connection.server.username
        let hash = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return "minidisc.navidrome.canonicalIDs.v1.\(connection.server.id).\(hash)"
    }

    @MainActor
    static func migrateRecords(modelContainer: ModelContainer, serverID: UUID, coversDirectory: URL) throws {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let convert = NavidromeCanonicalID.convert
        var covers: [String: String] = [:]
        func artwork(_ id: String?) -> String? {
            guard let id else { return nil }
            let replacement = NavidromeCanonicalID.artwork(id)
            if id != replacement { covers[id] = replacement }
            return replacement
        }
        func coverPath(_ path: String?) -> String? {
            guard let path else { return nil }
            let filename = (path as NSString).lastPathComponent
            guard let replacement = covers[filename] else { return path }
            return String(path.dropLast(filename.count)) + replacement
        }
        for track in try context.fetch(FetchDescriptor<DownloadedTrack>(predicate: #Predicate { $0.serverId == serverID })) {
            track.songId = convert(track.songId)
            track.albumId = track.albumId.map(convert)
            track.artistId = track.artistId.map(convert)
            track.coverArtId = artwork(track.coverArtId)
        }
        for track in try context.fetch(FetchDescriptor<CachedTrack>(predicate: #Predicate { $0.serverId == serverID })) {
            track.songId = convert(track.songId)
        }
        for album in try context.fetch(FetchDescriptor<DownloadedAlbum>(predicate: #Predicate { $0.serverId == serverID })) {
            album.albumId = convert(album.albumId)
            album.coverArtId = artwork(album.coverArtId)
            album.localCoverArtPath = coverPath(album.localCoverArtPath)
        }
        for playlist in try context.fetch(FetchDescriptor<DownloadedPlaylist>(predicate: #Predicate { $0.serverId == serverID })) {
            playlist.playlistId = convert(playlist.playlistId)
            playlist.songIds = playlist.songIds.map(convert)
            playlist.coverArtId = artwork(playlist.coverArtId)
            playlist.localCoverArtPath = coverPath(playlist.localCoverArtPath)
        }
        for queue in try context.fetch(FetchDescriptor<QueueSnapshot>(predicate: #Predicate { $0.serverId == serverID })) {
            queue.songIds = queue.songIds.map(convert)
        }
        for item in try context.fetch(FetchDescriptor<PinnedItem>(predicate: #Predicate { $0.serverId == serverID })) {
            item.itemId = convert(item.itemId)
            item.id = ServerItemIdentity.key(serverID: item.serverId, type: item.itemType, itemID: item.itemId)
            item.coverArtId = artwork(item.coverArtId)
        }
        for item in try context.fetch(FetchDescriptor<FavoriteRecord>(predicate: #Predicate { $0.serverId == serverID })) {
            item.itemId = convert(item.itemId)
            item.id = ServerItemIdentity.key(serverID: item.serverId, type: item.itemType, itemID: item.itemId)
        }
        for item in try context.fetch(FetchDescriptor<PlaylistCoverChoice>(predicate: #Predicate { $0.serverId == serverID })) {
            item.playlistId = convert(item.playlistId)
        }
        for item in try context.fetch(FetchDescriptor<CachedLyrics>(predicate: #Predicate { $0.serverId == serverID })) {
            let previous = item.songId
            item.songId = convert(previous)
            if item.compositeKey.hasSuffix(":" + previous) {
                item.compositeKey = String(item.compositeKey.dropLast(previous.count)) + item.songId
            }
        }
        let serverString = serverID.uuidString
        for event in try context.fetch(FetchDescriptor<PlaybackEvent>(predicate: #Predicate { $0.serverId == serverString })) {
            event.trackId = convert(event.trackId)
            event.albumId = event.albumId.map(convert)
            event.artistId = event.artistId.map(convert)
        }
        // Copy, rather than move: an interrupted migration and another server may
        // still reference the old name. No audio file is touched by this migration.
        for (old, new) in covers {
            guard !old.contains("/"), !new.contains("/"), old != ".", old != ".." else { continue }
            let source = coversDirectory.appendingPathComponent(old)
            let target = coversDirectory.appendingPathComponent(new)
            if FileManager.default.fileExists(atPath: source.path), !FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.copyItem(at: source, to: target)
            }
        }
        if context.hasChanges { try context.save() }
    }

    private func migratePreferences(serverID: UUID) {
        let suffix = "." + serverID.uuidString
        // Only these namespaces contain resource IDs. Cycle dates, mood names,
        // user settings, credentials and external MusicBrainz IDs stay untouched.
        for key in defaults.keys() where key.hasSuffix(suffix) {
            if key.hasPrefix("minidisc.mood.playlistId.") || key.hasPrefix("minidisc.wrapped.playlistId."),
               let id = defaults.string(forKey: key) {
                let replacement = NavidromeCanonicalID.convert(id)
                if id != replacement { defaults.set(replacement, forKey: key) }
            } else if key == "minidisc.recentPlaylistDestinations" + suffix, let ids = defaults.stringArray(forKey: key) {
                let replacement = ids.map(NavidromeCanonicalID.convert)
                if ids != replacement { defaults.set(replacement, forKey: key) }
            }
        }
    }

    nonisolated static func migrateDownloadJournal(at url: URL, serverID: UUID) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let jobs = try JSONDecoder().decode([QueuedDownload].self, from: Data(contentsOf: url))
        var changed = false
        let migrated = try jobs.map { job -> QueuedDownload in
            guard job.serverID == serverID else { return job }
            let originalSong = try JSONEncoder().encode(job.song)
            let owners = Set(job.owners.map { owner in
                switch owner {
                case .track: return owner
                case .album(let id): return .album(NavidromeCanonicalID.convert(id))
                case .playlist(let id): return .playlist(NavidromeCanonicalID.convert(id))
                }
            })
            guard try NavidromeCanonicalID.containsLegacyIDs(in: originalSong) || owners != job.owners else { return job }
            changed = true
            let data = try NavidromeCanonicalID.songData(originalSong)
            let song = try JSONDecoder().decode(Song.self, from: data)
            return QueuedDownload(id: job.id, song: song, serverID: job.serverID, owners: owners,
                                  status: job.status, received: job.received, expected: job.expected, error: job.error)
        }
        if changed { try JSONEncoder().encode(migrated).write(to: url, options: .atomic) }
    }
}
