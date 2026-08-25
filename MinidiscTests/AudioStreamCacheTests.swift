import Foundation
import SwiftData
import Testing
@testable import Minidisc

@Suite("Audio stream cache")
struct AudioStreamCacheTests {
    private func makeTemporaryFile(size: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("minidisc-cache-\(UUID().uuidString).tmp")
        try Data(repeating: 0x41, count: size).write(to: url)
        return url
    }

    @Test func fileStoreRoundTripUsesSafeGeneratedName() async throws {
        let container = try ModelContainer(
            for: Schema([CachedTrack.self, CachedLyrics.self]),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let cache = AudioStreamCache(modelContainer: container)
        let serverID = UUID()
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("minidisc-cache-\(UUID().uuidString).tmp")
        let payload = Data("ID3 playable audio payload".utf8)
        try payload.write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let storedURL = try await cache.store(
            fileAt: sourceURL,
            forSongId: "../server-controlled/path",
            serverId: serverID,
            mimeType: "audio/mpeg"
        )
        defer { try? FileManager.default.removeItem(at: storedURL) }

        #expect(!FileManager.default.fileExists(atPath: sourceURL.path))
        #expect(storedURL.pathExtension == "mp3")
        #expect(!storedURL.lastPathComponent.contains(".."))
        #expect(try Data(contentsOf: storedURL) == payload)
        #expect(await cache.cachedURL(forSongId: "../server-controlled/path", serverId: serverID) == storedURL)

        await cache.clearAllForServer(serverID)
        #expect(await cache.cachedURL(forSongId: "../server-controlled/path", serverId: serverID) == nil)
        #expect(!FileManager.default.fileExists(atPath: storedURL.path))
    }

    @Test func clearingAudioCachePreservesLyrics() async throws {
        let container = try ModelContainer(
            for: Schema([CachedTrack.self, CachedLyrics.self]),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let serverID = UUID()
        await MainActor.run {
            let context = ModelContext(container)
            context.insert(CachedLyrics(
                songId: "song-with-lyrics",
                serverId: serverID,
                jsonPayload: Data("{}".utf8)
            ))
            try? context.save()
        }

        let cache = AudioStreamCache(modelContainer: container)
        await cache.clearAllForServer(serverID)

        let lyricCount = await MainActor.run {
            let context = ModelContext(container)
            return (try? context.fetchCount(FetchDescriptor<CachedLyrics>())) ?? 0
        }
        #expect(lyricCount == 1)
    }

    @Test func identicalSongIDsRemainScopedToTheirServer() async throws {
        let container = try ModelContainer(
            for: Schema([CachedTrack.self, CachedLyrics.self]),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let cache = AudioStreamCache(modelContainer: container)
        let firstServerID = UUID()
        let secondServerID = UUID()

        let firstURL = try await cache.store(
            fileAt: makeTemporaryFile(size: 8),
            forSongId: "shared-song-id",
            serverId: firstServerID,
            mimeType: "audio/mpeg"
        )
        let secondURL = try await cache.store(
            fileAt: makeTemporaryFile(size: 12),
            forSongId: "shared-song-id",
            serverId: secondServerID,
            mimeType: "audio/mpeg"
        )

        #expect(await cache.cachedURL(forSongId: "shared-song-id", serverId: firstServerID) == firstURL)
        #expect(await cache.cachedURL(forSongId: "shared-song-id", serverId: secondServerID) == secondURL)

        await cache.clearAll()
    }

    @Test func byteBudgetEvictsLeastRecentlyUsedTrack() async throws {
        let container = try ModelContainer(
            for: Schema([CachedTrack.self, CachedLyrics.self]),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let cache = AudioStreamCache(modelContainer: container, maxBytes: 24)
        let serverID = UUID()

        let firstSource = try makeTemporaryFile(size: 10)
        let firstURL = try await cache.store(
            fileAt: firstSource,
            forSongId: "first",
            serverId: serverID,
            mimeType: "audio/mpeg"
        )
        try await Task.sleep(for: .milliseconds(2))

        let secondSource = try makeTemporaryFile(size: 10)
        let secondURL = try await cache.store(
            fileAt: secondSource,
            forSongId: "second",
            serverId: serverID,
            mimeType: "audio/mpeg"
        )
        try await Task.sleep(for: .milliseconds(2))

        #expect(await cache.cachedURL(forSongId: "first", serverId: serverID) == firstURL)
        try await Task.sleep(for: .milliseconds(2))

        let thirdSource = try makeTemporaryFile(size: 10)
        let thirdURL = try await cache.store(
            fileAt: thirdSource,
            forSongId: "third",
            serverId: serverID,
            mimeType: "audio/mpeg"
        )

        #expect(await cache.cachedURL(forSongId: "first", serverId: serverID) == firstURL)
        #expect(await cache.cachedURL(forSongId: "second", serverId: serverID) == nil)
        #expect(await cache.cachedURL(forSongId: "third", serverId: serverID) == thirdURL)
        #expect(await cache.usedBytes == 20)
        #expect(!FileManager.default.fileExists(atPath: secondURL.path))

        await cache.clearAllForServer(serverID)
    }
}
