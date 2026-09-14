import Foundation
import SwiftSonic
import Testing
@testable import Minidisc

@Suite("Music shortcuts")
@MainActor
struct MusicIntentTests {
    @Test func stableAccountIdentity() {
        let first = MusicIntentID.scope(baseURL: "HTTPS://Music.example:443/subsonic/", username: "alice")
        #expect(first == MusicIntentID.scope(baseURL: "https://music.example/subsonic", username: "alice"))
        #expect(first != MusicIntentID.scope(baseURL: "https://music.example/subsonic", username: "bob"))
        #expect(first != MusicIntentID.scope(baseURL: "https://music.example/other", username: "alice"))
        let reference = MusicIntentID(scope: first, kind: .song, resourceID: "a.b/été+123")
        #expect(MusicIntentID(rawValue: reference.rawValue) == reference)
        #expect(!reference.rawValue.contains("music.example"))
        #expect(!reference.rawValue.contains("alice"))
        #expect(MusicIntentID(rawValue: "v2.invalid") == nil)
    }

    @Test func indexResolvesBatchesAndSeparatesServers() async throws {
        let container = try makeContainer()
        let server = configure(container)
        let scope = MusicIntentID.scope(baseURL: server.baseURL, username: server.username)
        let other = UUID()
        try await container.libraryIndexStore.upsertTracks([
            Song(id: "one", title: "First"), Song(id: "two", title: "Second")
        ], serverID: server.id, generation: "test", serverOrderStart: 0)
        try await container.libraryIndexStore.upsertTracks([
            Song(id: "one", title: "Other account")
        ], serverID: other, generation: "test", serverOrderStart: 0)
        let ids = ["two", "missing", "one", "two"].map {
            MusicIntentID(scope: scope, kind: .song, resourceID: $0).rawValue
        }
        let service = MusicIntentService(container: container)
        let resolved = try await service.resolve(ids)
        #expect(resolved.map(\.title) == ["Second", "First", "Second"])
        #expect(resolved.allSatisfy { $0.reference.scope == scope })
    }

    @Test func refusesShortcutFromAnotherAccount() async throws {
        let container = try makeContainer()
        let server = configure(container)
        let wrong = MusicIntentID(scope: MusicIntentID.scope(baseURL: server.baseURL, username: "other"),
                                  kind: .song, resourceID: "one")
        do {
            _ = try await MusicIntentService(container: container).resolve([wrong.rawValue])
            Issue.record("A shortcut must not resolve against a different account")
        } catch MusicIntentError.differentServer {}
    }

    @Test func emptyPickerWithoutServer() async throws {
        let service = MusicIntentService(container: try makeContainer())
        #expect(try await service.suggestions().isEmpty)
        do {
            try await service.play(mood: .night)
            Issue.record("No server should produce an actionable error")
        } catch MusicIntentError.noServer {}
    }

    @Test func suggestionsAreBoundedAndLocal() async throws {
        let container = try makeContainer()
        let server = configure(container)
        try await container.libraryIndexStore.upsertTracks((0..<100).map {
            Song(id: "track-\($0)", title: "Track \($0)")
        }, serverID: server.id, generation: "test", serverOrderStart: 0)
        let records = try await MusicIntentService(container: container).suggestions()
        #expect(records.count == 8)
        #expect(records.allSatisfy { $0.reference.kind == .song })
    }

    @Test func exactTitlesPrecedePrefixMatches() {
        #expect(MusicIntentService.matchRank("Été", term: "ete") < MusicIntentService.matchRank("Été indien", term: "ete"))
        #expect(MusicIntentService.matchesPlaylist("Minidisc · Night", term: "night"))
        #expect(!MusicIntentService.matchesPlaylist("My Favorites", term: "night"))
    }

    @Test func simultaneousLaunchesShareTheSameContainer() async throws {
        let expected = try makeContainer()
        var loads = 0
        let runtime = MinidiscRuntime {
            loads += 1
            await Task.yield()
            return expected
        }
        async let first = runtime.container()
        async let second = runtime.container()
        let values = try await (first, second)
        #expect(values.0 === expected)
        #expect(values.1 === expected)
        #expect(loads == 1)
        #expect(try await runtime.container() === expected)
        #expect(loads == 1)
    }

    @Test func failedLaunchCanRetry() async throws {
        let expected = try makeContainer()
        var attempts = 0
        let runtime = MinidiscRuntime {
            attempts += 1
            if attempts == 1 { throw MusicIntentError.unavailable }
            return expected
        }
        do {
            _ = try await runtime.container()
            Issue.record("Expected initial failure")
        } catch MusicIntentError.unavailable {}
        #expect(try await runtime.container() === expected)
        #expect(attempts == 2)
    }

    private func makeContainer() throws -> AppContainer {
        let defaults = try #require(UserDefaults(suiteName: "MusicIntentTests.\(UUID())"))
        return try AppContainer(inMemory: true, userDefaults: defaults)
    }

    private func configure(_ container: AppContainer) -> ServerSnapshot {
        let server = ServerSnapshot(from: ServerConfig(displayName: "Fixture", baseURL: "https://music.example", username: "alice"))
        container.serverState.activeServer = server
        container.serverState.activeConnectionVersion = .init(serverID: server.id, revision: 1)
        container.serverState.isOnline = false
        return server
    }
}
