// Minidisc — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftData
import Testing
@testable import Minidisc

@Suite("Audio stream cache")
struct AudioStreamCacheTests {
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
}
