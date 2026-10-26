import Foundation
import SwiftData
import SwiftSonic
import Testing
@testable import Minidisc

@Suite("Navidrome 0.64 compatibility")
struct NavidromeCompatibilityTests {
    private let legacy = "e3b7fc2ae9447bbec37a13bf916e3cf6"
    private let canonical = "6VHl3uR4kss6sUPKA8Cwnk"
    private let playlist = "f47ac10b-58cc-4372-a567-0e02b2c3d479"

    // Golden values are copied from Navidrome's id_canonical_test.go at v0.64.0.
    @Test(arguments: [
        ("5cLJPkLA5DK2BADhoeotPk", "5cLJPkLA5DK2BADhoeotPk"),
        ("zzzzzzzzzzzzzzzzzzzzzz", "3LyqmwQBm5IRqlVjNYASwb"),
        ("e3b7fc2ae9447bbec37a13bf916e3cf6", "6VHl3uR4kss6sUPKA8Cwnk"),
        ("f47ac10b-58cc-4372-a567-0e02b2c3d479", "7rke2SAWaicSeSYzkhww6R"),
        ("", ""), ("aB3xY9kQz1", "aB3xY9kQz1"), ("0123456789abcdef", "0123456789abcdef"),
        ("!!!!!!!!!!!!!!!!!!!!!!", "!!!!!!!!!!!!!!!!!!!!!!"),
        ("zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz", "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"),
        ("000000000000000000000000000000000000", "000000000000000000000000000000000000")
    ])
    func matchesServerMigration(input: String, expected: String) {
        #expect(NavidromeCanonicalID.convert(input) == expected)
        #expect(NavidromeCanonicalID.convert(expected) == expected)
    }

    @Test(arguments: [
        ("navidrome", "0.63.1", false), ("Navidrome", "0.64.0 (1072e9f)", true),
        ("navidrome", "v0.64.1", true), ("navidrome", "0.65.0", true),
        ("navidrome", "1.0.0", true), ("gonic", "0.64.0", false),
        ("navidrome", "unknown", false), ("navidrome", "0.64", false),
        ("navidrome", "0.64.0-SNAPSHOT", false), ("navidrome", "0.64.0-rc.1", false)
    ])
    func gatesByImplementationAndVersion(type: String, version: String, expected: Bool) {
        #expect(NavidromeCanonicalID.isRequired(serverType: type, version: version) == expected)
    }

    @Test func artworkSuffixesAndMusicBrainzIDsArePreserved() throws {
        #expect(NavidromeCanonicalID.artwork("al-\(legacy)_65abc") == "al-\(canonical)_65abc")
        #expect(NavidromeCanonicalID.artwork("dc-\(legacy):2_deadbeef12345678") == "dc-\(canonical):2_deadbeef12345678")
        #expect(NavidromeCanonicalID.artwork("pl-\(playlist)_0") == "pl-7rke2SAWaicSeSYzkhww6R_0")
        #expect(NavidromeCanonicalID.artwork("al-") == "al-")
        let input: [String: Any] = ["id": legacy, "title": playlist, "musicBrainzId": playlist,
                                  "coverArt": "mf-\(legacy)", "artists": [["id": legacy, "musicBrainzId": playlist]]]
        let output = try #require(JSONSerialization.jsonObject(with: NavidromeCanonicalID.songData(JSONSerialization.data(withJSONObject: input))) as? [String: Any])
        #expect(output["id"] as? String == canonical)
        #expect(output["musicBrainzId"] as? String == playlist)
        #expect(output["title"] as? String == playlist)
        #expect((output["artists"] as? [[String: String]])?.first?["id"] == canonical)
        #expect((output["artists"] as? [[String: String]])?.first?["musicBrainzId"] == playlist)
    }

    @MainActor
    @Test func migratesOwnedDataWithoutLosingAudioOrOtherServers() throws {
        let container = try ModelContainer.minidisc(inMemory: true)
        let context = ModelContext(container)
        let serverID = UUID(), otherServerID = UUID()
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("retained.flac")
        try Data([1, 2, 3, 4]).write(to: audio)
        let coverID = "al-\(legacy)_0"
        try Data([5, 6]).write(to: directory.appendingPathComponent(coverID))
        context.insert(DownloadedTrack(songId: legacy, serverId: serverID, albumId: legacy,
            filePath: audio.path, fileSize: 4, mimeType: "audio/flac", title: "Kept", coverArtId: coverID))
        context.insert(DownloadedTrack(songId: legacy, serverId: otherServerID,
            filePath: "other.flac", fileSize: 100, mimeType: "audio/flac", title: "Other"))
        context.insert(CachedTrack(songId: legacy, serverId: serverID, filePath: "cache.flac", fileSize: 4, mimeType: "audio/flac"))
        context.insert(DownloadedPlaylist(playlistId: playlist, serverId: serverID, name: "Night",
            tracksCount: 2, totalTracksCount: 2, songIds: [legacy, legacy]))
        context.insert(DownloadedAlbum(albumId: legacy, serverId: serverID, name: "Album", tracksCount: 1,
                                       totalTracksCount: 1, coverArtId: coverID, localCoverArtPath: coverID))
        context.insert(FavoriteRecord(itemType: .song, itemId: legacy, starredDate: .now, serverId: serverID))
        context.insert(CachedLyrics(songId: legacy, serverId: serverID, jsonPayload: Data("{}".utf8)))
        context.insert(PinnedItem(itemType: .playlist, itemId: playlist, displayName: "Night", displaySubtitle: "",
            coverArtId: coverID, serverId: serverID, sortOrder: 2))
        context.insert(PlaybackEvent(trackId: legacy, trackTitle: "Kept", albumId: legacy, albumTitle: "Album",
            artistId: legacy, artistName: "Artist", genre: nil, durationListened: 99, trackDuration: 120,
            wasCompleted: true, serverId: serverID.uuidString))
        try context.save()
        try NavidromeCompatibility.migrateRecords(modelContainer: container, serverID: serverID, coversDirectory: directory)
        // A retry must neither duplicate rows nor transform already-canonical IDs.
        try NavidromeCompatibility.migrateRecords(modelContainer: container, serverID: serverID, coversDirectory: directory)
        let read = ModelContext(container)
        let tracks = try read.fetch(FetchDescriptor<DownloadedTrack>())
        #expect(tracks.count == 2)
        #expect(tracks.first(where: { $0.serverId == serverID })?.songId == canonical)
        #expect(tracks.first(where: { $0.serverId == serverID })?.filePath == audio.path)
        #expect(tracks.first(where: { $0.serverId == otherServerID })?.songId == legacy)
        #expect(try Data(contentsOf: audio) == Data([1, 2, 3, 4]))
        #expect(try Data(contentsOf: directory.appendingPathComponent("al-\(canonical)_0")) == Data([5, 6]))
        #expect(try read.fetch(FetchDescriptor<CachedTrack>()).first?.songId == canonical)
        let downloadedPlaylist = try #require(read.fetch(FetchDescriptor<DownloadedPlaylist>()).first)
        #expect(downloadedPlaylist.playlistId == "7rke2SAWaicSeSYzkhww6R")
        #expect(downloadedPlaylist.songIds == [canonical, canonical])
        #expect(try read.fetch(FetchDescriptor<PinnedItem>()).first?.id == ServerItemIdentity.key(serverID: serverID, type: "playlist", itemID: "7rke2SAWaicSeSYzkhww6R"))
        let event = try #require(read.fetch(FetchDescriptor<PlaybackEvent>()).first)
        #expect(event.trackId == canonical)
        #expect(event.durationListened == 99)
        #expect(try read.fetch(FetchDescriptor<DownloadedAlbum>()).first?.localCoverArtPath == "al-\(canonical)_0")
        #expect(try read.fetch(FetchDescriptor<FavoriteRecord>()).first?.id == ServerItemIdentity.key(serverID: serverID, type: "song", itemID: canonical))
        #expect(try read.fetch(FetchDescriptor<CachedLyrics>()).first?.compositeKey.hasSuffix(":" + canonical) == true)
    }

    @MainActor
    @Test func preservesRestoredQueuePositionAndRepeatMode() async throws {
        let container = try ModelContainer.session(inMemory: true)
        let service = PlaybackSessionService(modelContainer: container)
        let song = try JSONDecoder().decode(Song.self, from: Data("{\"id\":\"\(legacy)\",\"title\":\"Track\",\"isDir\":false,\"duration\":200}".utf8))
        let track = DisplayableSong(from: song)
        await service.save(playerState: SessionPayload(currentIndex: 1, currentPosition: 73,
            queue: [track, track], currentTrack: track, repeatMode: .all))
        try await service.migrateNavidromeIDs()
        let restored = try #require(await service.loadRestoredSession())
        #expect(restored.queue.map(\.id) == [canonical, canonical])
        #expect(restored.currentPosition == 73)
        #expect(restored.currentIndex == 1)
        #expect(restored.repeatMode == .all)
    }

    @MainActor
    @Test func defersOfflineAndOlderServersThenMigratesExactlyOnce() async throws {
        let container = try ModelContainer.minidisc(inMemory: true)
        let sessions = PlaybackSessionService(modelContainer: try ModelContainer.session(inMemory: true))
        let index = LibraryIndexStore(modelContainer: try ModelContainer.libraryIndex(inMemory: true))
        let suite = "NavidromeCompatibilityTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = URL.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let probe = CompatibilityProbe()
        let compatibility = NavidromeCompatibility(modelContainer: container, sessionService: sessions,
            indexStore: index, defaults: defaults, homeCache: HomeFeedCache(directory: directory),
            coversDirectory: directory, journalURL: directory.appendingPathComponent("queue.json"),
            probe: { try await probe.fetch($0) })
        let config = ServerConfig(displayName: "Test", baseURL: "https://music.example.invalid", username: "fixture")
        let connection = try ServerConnection(version: .init(serverID: config.id, revision: 1),
            server: ServerSnapshot(from: config), credentials: ServerCredentials(password: "fixture", customHeaders: [:]))
        let moodKey = "minidisc.mood.playlistId.night.\(config.id)"
        let wrappedKey = "minidisc.wrapped.playlistId.2026.\(config.id)"
        let recentKey = "minidisc.recentPlaylistDestinations.\(config.id)"
        defaults.set(playlist, forKey: moodKey)
        defaults.set(playlist, forKey: wrappedKey)
        defaults.set([playlist], forKey: recentKey)
        let context = ModelContext(container)
        context.insert(DownloadedTrack(songId: legacy, serverId: config.id, filePath: "keep.flac", fileSize: 4,
                                       mimeType: "audio/flac", title: "Keep"))
        try context.save()

        // First call is offline; second is still 0.63. Neither sets the completion marker.
        try await compatibility.prepare(connection, restoringSession: false)
        try await compatibility.prepare(connection, restoringSession: false)
        #expect(defaults.string(forKey: moodKey) == playlist)
        #expect(try ModelContext(container).fetch(FetchDescriptor<DownloadedTrack>()).first?.songId == legacy)
        // Third call observes 0.64. A subsequent activation must not probe again.
        try await compatibility.prepare(connection, restoringSession: false)
        try await compatibility.prepare(connection, restoringSession: false)
        #expect(await probe.calls == 3)
        #expect(defaults.string(forKey: moodKey) == "7rke2SAWaicSeSYzkhww6R")
        #expect(defaults.string(forKey: wrappedKey) == "7rke2SAWaicSeSYzkhww6R")
        #expect(defaults.stringArray(forKey: recentKey) == ["7rke2SAWaicSeSYzkhww6R"])
        #expect(try ModelContext(container).fetch(FetchDescriptor<DownloadedTrack>()).first?.songId == canonical)
    }

    @Test func migratesPendingDownloadsWithoutChangingTransferIdentity() throws {
        let url = URL.temporaryDirectory.appendingPathComponent("navidrome-journal-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let server = UUID(), other = UUID()
        let song = try JSONDecoder().decode(Song.self, from: Data("{\"id\":\"\(legacy)\",\"title\":\"Track\",\"isDir\":false}".utf8))
        let job = QueuedDownload(id: UUID(), song: song, serverID: server, owners: [.playlist(playlist), .album(legacy)])
        let otherJob = QueuedDownload(id: UUID(), song: song, serverID: other, owners: [.track])
        try JSONEncoder().encode([job, otherJob]).write(to: url)
        try NavidromeCompatibility.migrateDownloadJournal(at: url, serverID: server)
        let jobs = try JSONDecoder().decode([QueuedDownload].self, from: Data(contentsOf: url))
        #expect(jobs.map(\.id) == [job.id, otherJob.id])
        #expect(jobs[0].song.id == canonical)
        #expect(jobs[0].owners == [.playlist("7rke2SAWaicSeSYzkhww6R"), .album(canonical)])
        #expect(jobs[1].song.id == legacy)
    }

    @MainActor
    @Test(arguments: [
        ("navidrome", "0.63.1", true, false),
        ("airsonic", "0.64.0", true, false),
        ("navidrome", "unknown", true, false),
        ("navidrome", "0.64.0-SNAPSHOT", true, false),
        ("navidrome", "0.64.0", false, false),
        ("navidrome", "0.64.0 (1072e9f)", true, true)
    ])
    func onlyResyncsAffectedUpgradedNavidrome(type: String, version: String, oldIDs: Bool, shouldReset: Bool) async throws {
        let container = try ModelContainer.minidisc(inMemory: true)
        let sessions = PlaybackSessionService(modelContainer: try ModelContainer.session(inMemory: true))
        let index = LibraryIndexStore(modelContainer: try ModelContainer.libraryIndex(inMemory: true))
        let suite = "NavidromeGating.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = URL.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let config = ServerConfig(displayName: "Test", baseURL: "https://example.invalid", username: "fixture")
        let otherServer = UUID()
        let id = oldIDs ? legacy : canonical
        let song = try JSONDecoder().decode(Song.self, from: Data("{\"id\":\"\(id)\",\"title\":\"Track\",\"isDir\":false}".utf8))
        try await index.upsertTracks([song], serverID: config.id, generation: "old", serverOrderStart: 0)
        try await index.upsertTracks([song], serverID: otherServer, generation: "other", serverOrderStart: 0)
        let context = ModelContext(container)
        context.insert(DownloadedTrack(songId: id, serverId: config.id, filePath: "retained.flac", fileSize: 4,
                                       mimeType: "audio/flac", title: "Track"))
        try context.save()
        let caps = ServerCapabilities(apiVersion: "1.16.1", isOpenSubsonic: true,
                                      serverType: type, serverVersion: version, extensions: [:])
        let compatibility = NavidromeCompatibility(modelContainer: container, sessionService: sessions,
            indexStore: index, defaults: defaults, homeCache: HomeFeedCache(directory: directory),
            coversDirectory: directory, journalURL: directory.appendingPathComponent("queue.json"), probe: { _ in caps })
        let connection = try ServerConnection(version: .init(serverID: config.id, revision: 1),
            server: ServerSnapshot(from: config), credentials: ServerCredentials(password: "fixture", customHeaders: [:]))
        try await compatibility.prepare(connection, restoringSession: true)
        #expect(try await index.counts(for: config.id).tracks == (shouldReset ? 0 : 1))
        #expect(try await index.counts(for: otherServer).tracks == 1)
        let track = try #require(ModelContext(container).fetch(FetchDescriptor<DownloadedTrack>()).first)
        #expect(track.songId == (shouldReset ? canonical : id))
        #expect(track.filePath == "retained.flac")
        // Even after a successful migration, newly synchronized data must remain on reactivation.
        let freshSong = try JSONDecoder().decode(Song.self, from: Data("{\"id\":\"\(canonical)\",\"title\":\"Track\",\"isDir\":false}".utf8))
        if shouldReset {
            try await index.upsertTracks([freshSong], serverID: config.id, generation: "new", serverOrderStart: 0)
            try await compatibility.prepare(connection, restoringSession: true)
            #expect(try await index.counts(for: config.id).tracks == 1)
        }
    }

    @MainActor
    @Test func retriesIncompleteMigrationBeforePublishingRestoredConnection() async throws {
        let container = try ModelContainer.minidisc(inMemory: true)
        let sessions = PlaybackSessionService(modelContainer: try ModelContainer.session(inMemory: true))
        let index = LibraryIndexStore(modelContainer: try ModelContainer.libraryIndex(inMemory: true))
        let suite = "NavidromeRetry.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = URL.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let journal = directory.appendingPathComponent("queue.json")
        try Data("broken journal".utf8).write(to: journal)
        let compatibility = NavidromeCompatibility(modelContainer: container, sessionService: sessions,
            indexStore: index, defaults: defaults, homeCache: HomeFeedCache(directory: directory),
            coversDirectory: directory, journalURL: journal, probe: { _ in
                ServerCapabilities(apiVersion: "1.16.1", isOpenSubsonic: true, serverType: "navidrome",
                                   serverVersion: "0.64.0", extensions: [:])
            })
        let config = ServerConfig(displayName: "Test", baseURL: "https://example.invalid", username: "fixture", isActive: true)
        let context = ModelContext(container)
        context.insert(config)
        try context.save()
        let song = try JSONDecoder().decode(Song.self, from: Data("{\"id\":\"\(legacy)\",\"title\":\"Track\",\"isDir\":false}".utf8))
        try await index.upsertTracks([song], serverID: config.id, generation: "old", serverOrderStart: 0)
        let track = DisplayableSong(from: song)
        await sessions.save(playerState: SessionPayload(currentIndex: 0, currentPosition: 47,
            queue: [track], currentTrack: track, repeatMode: .off))
        let credentials = ServerCredentials(password: "fixture", customHeaders: [:])
        let connection = try ServerConnection(version: .init(serverID: config.id, revision: 1),
            server: ServerSnapshot(from: config), credentials: credentials)
        await #expect(throws: (any Error).self) {
            try await compatibility.prepare(connection, restoringSession: true)
        }
        #expect(!defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix("minidisc.navidrome.canonicalIDs") })
        #expect(try await index.counts(for: config.id).tracks == 1)
        try Data("[]".utf8).write(to: journal)
        let keychain = MockKeychain()
        try await keychain.store(credentials, forKey: ServerCredentials.keychainKey(for: config.id))
        let state = ServerState()
        let server = ServerService(state: state, keychain: keychain, modelContainer: container,
                                   audioStreamCache: MockAudioStreamCache(), compatibility: compatibility)
        await server.loadPersistedState()
        #expect(state.activeConnectionVersion?.serverID == config.id)
        #expect(try await index.counts(for: config.id).tracks == 0)
        let restored = try #require(await sessions.loadRestoredSession())
        #expect(restored.queue.first?.id == canonical)
        #expect(restored.currentPosition == 47)
    }
}

private actor CompatibilityProbe {
    private(set) var calls = 0
    func fetch(_ connection: ServerConnection) throws -> ServerCapabilities {
        calls += 1
        if calls == 1 { throw URLError(.notConnectedToInternet) }
        return ServerCapabilities(apiVersion: "1.16.1", isOpenSubsonic: true, serverType: "navidrome",
                                  serverVersion: calls == 2 ? "0.63.1" : "0.64.0", extensions: [:])
    }
}
