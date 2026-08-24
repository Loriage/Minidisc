import Testing
import Foundation
import SwiftData
@testable import Minidisc

// MARK: - Mock

@MainActor
final class MockKeychain: KeychainServiceProtocol {
    private var storage: [String: Data] = [:]
    private var failOnStore = false

    func setShouldFailOnStore(_ value: Bool) { failOnStore = value }

    func store<T: Codable & Sendable>(_ value: T, forKey key: String) async throws {
        if failOnStore { throw MinidiscError.keychainWriteFailed(-1) }
        storage[key] = try JSONEncoder().encode(value)
    }

    func retrieve<T: Codable & Sendable>(_ type: T.Type, forKey key: String) async throws -> T? {
        guard let data = storage[key] else { return nil }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func delete(forKey key: String) async throws {
        storage.removeValue(forKey: key)
    }
}

@MainActor
final class MockAudioStreamCache: AudioStreamCacheProtocol {
    var usedBytes: Int64 = 0
    var trackCount: Int = 0
    func cachedURL(forSongId songId: String, serverId: UUID) async -> URL? { nil }
    func store(fileAt sourceURL: URL, forSongId songId: String, serverId: UUID, mimeType: String) async throws -> URL {
        struct MockError: Error {}; throw MockError()
    }
    func setMaxTracks(_ value: Int) async {}
    func invalidate(songId: String, serverId: UUID) async {}
    func clearAll() async {}
    func clearAllForServer(_ serverId: UUID) async {}
}

// MARK: - Suite

@Suite("ServerService")
@MainActor
struct ServerServiceTests {

    private func makeService(keychain: MockKeychain? = nil) throws -> (ServerService, ServerState) {
        // Default argument expressions are nonisolated — resolve the @MainActor
        // mock inside the MainActor method body instead.
        let keychain = keychain ?? MockKeychain()
        let container = try ModelContainer.minidisc(inMemory: true)
        let state = ServerState()
        let service = ServerService(state: state, keychain: keychain, modelContainer: container, audioStreamCache: MockAudioStreamCache())
        return (service, state)
    }

    // MARK: addServer

    @Test func addServer_firstServer_becomesActive() async throws {
        let (service, state) = try makeService()

        try await service.addServer(
            displayName: "My Server", baseURL: "https://music.example.com",
            username: "admin", password: "secret", customHeaders: [:]
        )

        #expect(state.servers.count == 1)
        #expect(state.activeServer?.username == "admin")
        #expect(state.activeServer?.displayName == "My Server")
    }

    @Test func addServer_secondServer_doesNotBecomeActive() async throws {
        let (service, state) = try makeService()

        try await service.addServer(
            displayName: "S1", baseURL: "https://s1.example.com",
            username: "user1", password: "pass", customHeaders: [:]
        )
        try await service.addServer(
            displayName: "S2", baseURL: "https://s2.example.com",
            username: "user2", password: "pass", customHeaders: [:]
        )

        #expect(state.servers.count == 2)
        #expect(state.activeServer?.username == "user1")
    }

    @Test func addServer_invalidHeaderName_throwsInvalidHeaderName() async throws {
        let (service, _) = try makeService()

        await #expect(throws: MinidiscError.self) {
            try await service.addServer(
                displayName: "S", baseURL: "https://s.example.com",
                username: "u", password: "p",
                customHeaders: ["Bad Header": "value"]
            )
        }
    }

    @Test func addServer_keychainFailure_stateUnchanged() async throws {
        let keychain = MockKeychain()
        keychain.setShouldFailOnStore(true)
        let (service, state) = try makeService(keychain: keychain)

        try? await service.addServer(
            displayName: "S", baseURL: "https://s.example.com",
            username: "u", password: "p", customHeaders: [:]
        )

        #expect(state.servers.isEmpty)
        #expect(state.activeServer == nil)
    }

    // MARK: removeServer

    @Test func removeServer_removesFromStateAndClearsActive() async throws {
        let (service, state) = try makeService()

        try await service.addServer(
            displayName: "S", baseURL: "https://s.example.com",
            username: "u", password: "p", customHeaders: [:]
        )
        let id = try #require(state.servers.first).id
        try await service.removeServer(id: id)

        #expect(state.servers.isEmpty)
        #expect(state.activeServer == nil)
        #expect(state.isConnected == false)
    }

    @Test func removeServer_unknownId_throwsServerNotFound() async throws {
        let (service, _) = try makeService()

        await #expect(throws: MinidiscError.self) {
            try await service.removeServer(id: UUID())
        }
    }

    // MARK: setActiveServer

    @Test func setActiveServer_switchesActiveServer() async throws {
        let (service, state) = try makeService()

        try await service.addServer(
            displayName: "S1", baseURL: "https://s1.example.com",
            username: "user1", password: "pass", customHeaders: [:]
        )
        try await service.addServer(
            displayName: "S2", baseURL: "https://s2.example.com",
            username: "user2", password: "pass", customHeaders: [:]
        )

        let s2Id = try #require(state.servers.first(where: { $0.username == "user2" })).id
        try await service.setActiveServer(id: s2Id)

        #expect(state.activeServer?.username == "user2")
        #expect(state.isConnected == false)
    }

    @Test func setActiveServer_unknownId_throwsServerNotFound() async throws {
        let (service, _) = try makeService()

        await #expect(throws: MinidiscError.self) {
            try await service.setActiveServer(id: UUID())
        }
    }

    // MARK: credential updates

    @Test func credentialUpdates_preserveAudioMuseToken() async throws {
        let (service, state) = try makeService()
        try await service.addServer(
            displayName: "S", baseURL: "https://s.example.com",
            username: "u", password: "old-password", customHeaders: ["X-Old": "1"]
        )
        let id = try #require(state.activeServer?.id)
        try await service.setAudioMuseConfig(
            serverId: id,
            urlString: "https://audiomuse.example.com",
            token: "audiomuse-token"
        )

        try await service.updateCustomHeaders(["X-New": "2"], forServer: id)
        var credentials = try await service.activeConnection().credentials
        #expect(credentials.audioMuseToken == "audiomuse-token")
        #expect(credentials.customHeaders == ["X-New": "2"])

        try await service.updateServer(
            id: id,
            displayName: "Renamed",
            baseURL: "https://new.example.com",
            username: "new-user",
            password: "new-password",
            customHeaders: ["X-Final": "3"]
        )
        credentials = try await service.activeConnection().credentials
        #expect(credentials.audioMuseToken == "audiomuse-token")
        #expect(credentials.password == "new-password")
        #expect(credentials.customHeaders == ["X-Final": "3"])
    }

    @Test func activeConnectionVersionChangesWithActiveConfiguration() async throws {
        let (service, state) = try makeService()
        try await service.addServer(
            displayName: "S",
            baseURL: "https://s.example.com",
            username: "u",
            password: "p",
            customHeaders: ["X-First": "1"]
        )
        let serverID = try #require(state.activeServer?.id)
        let firstVersion = try #require(await service.activeConnectionVersion())

        try await service.updateCustomHeaders(["X-Second": "2"], forServer: serverID)

        let secondVersion = try #require(await service.activeConnectionVersion())
        let connection = try await service.activeConnection()
        #expect(secondVersion.serverID == serverID)
        #expect(secondVersion.revision > firstVersion.revision)
        #expect(connection.version == secondVersion)
        #expect(connection.credentials.customHeaders == ["X-Second": "2"])
        #expect(state.activeConnectionVersion == secondVersion)
    }

    @Test func activeConnectionDoesNotReconstructCredentialsFromKeychain() async throws {
        let keychain = MockKeychain()
        let (service, state) = try makeService(keychain: keychain)
        try await service.addServer(
            displayName: "S",
            baseURL: "https://s.example.com",
            username: "u",
            password: "original",
            customHeaders: ["X-Original": "1"]
        )
        let serverID = try #require(state.activeServer?.id)
        try await keychain.store(
            ServerCredentials(password: "replacement", customHeaders: ["X-Replacement": "2"]),
            forKey: ServerCredentials.keychainKey(for: serverID)
        )

        let connection = try await service.activeConnection()

        #expect(connection.credentials.password == "original")
        #expect(connection.credentials.customHeaders == ["X-Original": "1"])
    }

    @Test func updateUnknownServer_rollsBackOrphanedCredentials() async throws {
        let keychain = MockKeychain()
        let (service, _) = try makeService(keychain: keychain)
        let unknownId = UUID()

        await #expect(throws: MinidiscError.self) {
            try await service.updateServer(
                id: unknownId,
                displayName: "Missing",
                baseURL: "https://missing.example.com",
                username: "u",
                password: "must-not-survive",
                customHeaders: [:]
            )
        }

        let stored = try await keychain.retrieve(
            ServerCredentials.self,
            forKey: ServerCredentials.keychainKey(for: unknownId)
        )
        #expect(stored == nil)
    }

    @Test func audioMuseUpdateForMissingServer_restoresPreviousCredentials() async throws {
        let keychain = MockKeychain()
        let (service, _) = try makeService(keychain: keychain)
        let unknownId = UUID()
        let original = ServerCredentials(
            password: "existing-password",
            customHeaders: ["X-Existing": "1"],
            audioMuseToken: "existing-token"
        )
        let key = ServerCredentials.keychainKey(for: unknownId)
        try await keychain.store(original, forKey: key)

        await #expect(throws: MinidiscError.self) {
            try await service.setAudioMuseConfig(
                serverId: unknownId,
                urlString: "https://new.example.com",
                token: "new-token"
            )
        }

        let restored = try #require(try await keychain.retrieve(ServerCredentials.self, forKey: key))
        #expect(restored.password == original.password)
        #expect(restored.customHeaders == original.customHeaders)
        #expect(restored.audioMuseToken == original.audioMuseToken)
    }

    // MARK: loadPersistedState

    @Test func loadPersistedState_restoresServersAndActiveServer() async throws {
        let keychain = MockKeychain()
        let container = try ModelContainer.minidisc(inMemory: true)

        let state1 = ServerState()
        let service1 = ServerService(state: state1, keychain: keychain, modelContainer: container, audioStreamCache: MockAudioStreamCache())
        try await service1.addServer(
            displayName: "Persisted", baseURL: "https://s.example.com",
            username: "user", password: "pass", customHeaders: [:]
        )

        // Simulate app restart: new service with the same container
        let state2 = ServerState()
        let service2 = ServerService(state: state2, keychain: keychain, modelContainer: container, audioStreamCache: MockAudioStreamCache())

        #expect(state2.servers.isEmpty)
        await service2.loadPersistedState()

        #expect(state2.servers.count == 1)
        #expect(state2.activeServer?.username == "user")
        #expect(state2.isLoadingPersistedState == false)
    }
}
