import Foundation
import SwiftData
import SwiftSonic
import Testing
@testable import Minidisc

@Suite @MainActor
struct ServerLibraryIsolationTests {
    @Test func changingLibraryKeepsOldMediaSeparateAndReturningRestoresItsScope() async throws {
        let models = try ModelContainer.minidisc(inMemory: true)
        let keychain = MockKeychain()
        let state = ServerState()
        let service = ServerService(state: state, keychain: keychain, modelContainer: models, audioStreamCache: MockAudioStreamCache())
        try await service.addServer(displayName: "Original", baseURL: "https://a.invalid", username: "u", password: "old", customHeaders: [:])
        let oldID = try #require(state.activeServer?.id)
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("old.mp3")
        try Data([1, 2, 3]).write(to: file)
        models.mainContext.insert(DownloadedTrack(songId: "same", serverId: oldID, filePath: "old.mp3", fileSize: 3, mimeType: "audio/mpeg", title: "Old track"))
        try models.mainContext.save()
        let stopped = StopCounter()
        await service.setLibraryChangeHandler { await stopped.record() }
        try await service.updateServer(id: oldID, displayName: "New", baseURL: "https://b.invalid", username: "u", password: "new", customHeaders: [:])
        let newID = try #require(state.activeServer?.id)
        #expect(newID != oldID)
        #expect(await stopped.count == 1)
        let reader = OfflineLibraryReader(modelContainer: models, downloadsDirectory: directory)
        #expect(await reader.downloadedURL(forSongId: "same", serverId: newID) == nil)
        #expect(await reader.downloadedURL(forSongId: "same", serverId: oldID) == file)
        #expect(try await service.activeConnection().credentials.password == "new")

        // Reload the service to prove the mapping is persisted, not an in-memory cache.
        let restored = ServerService(state: ServerState(), keychain: keychain, modelContainer: models, audioStreamCache: MockAudioStreamCache())
        await restored.loadPersistedState()
        try await restored.updateServer(id: newID, displayName: "Original", baseURL: "https://a.invalid", username: "u", password: "old", customHeaders: [:])
        let connection = try await restored.activeConnection()
        #expect(connection.version.serverID == oldID)
        #expect(await reader.downloadedURL(forSongId: "same", serverId: connection.version.serverID) == file)
        #expect(try models.mainContext.fetchCount(FetchDescriptor<DownloadedTrack>()) == 1)
    }

    @Test func failedCredentialWriteDoesNotSwitchTheLibrary() async throws {
        let models = try ModelContainer.minidisc(inMemory: true)
        let keychain = MockKeychain()
        let state = ServerState()
        let service = ServerService(state: state, keychain: keychain, modelContainer: models, audioStreamCache: MockAudioStreamCache())
        try await service.addServer(displayName: "A", baseURL: "https://a.invalid", username: "u", password: "old", customHeaders: [:])
        let id = try #require(state.activeServer?.id)
        keychain.setShouldFailOnStore(true)
        await #expect(throws: MinidiscError.self) {
            try await service.updateServer(id: id, displayName: "B", baseURL: "https://b.invalid", username: "other", password: "new", customHeaders: [:])
        }
        #expect(state.activeServer?.id == id)
        #expect(state.activeServer?.baseURL == "https://a.invalid")
        #expect(try await service.activeConnection().credentials.password == "old")
    }

    @Test func oldPlaybackSessionCannotRestoreOnAnotherLibrary() async throws {
        let sessions = PlaybackSessionService(modelContainer: try ModelContainer.session(inMemory: true))
        let oldID = UUID()
        let song = DisplayableSong(from: Song(id: "same", title: "Original"))
        await sessions.save(playerState: SessionPayload(currentIndex: 0, currentPosition: 12,
            queue: [song], currentTrack: song, repeatMode: .off, serverId: oldID))
        #expect(await sessions.loadRestoredSession(serverID: UUID()) == nil)
        #expect(await sessions.loadRestoredSession(serverID: oldID)?.queue.first?.title == "Original")
    }

    @Test func equivalentURLsKeepTheirScopeButAnotherAccountDoesNot() throws {
        let id = UUID()
        let equivalent = try ServerLibraryScopes.select(currentID: id, currentURL: "https://music.invalid/rest/", currentUser: "u", saved: nil, url: "https://MUSIC.invalid:443/rest", user: "u")
        #expect(equivalent.id == id)
        let other = try ServerLibraryScopes.select(currentID: id, currentURL: "https://music.invalid/rest", currentUser: "u", saved: equivalent.data, url: "https://music.invalid/rest", user: "other")
        #expect(other.id != id)
    }
}

private actor StopCounter {
    var count = 0
    func record() { count += 1 }
}
