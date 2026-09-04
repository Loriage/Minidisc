import Foundation
import SwiftSonic
import Testing
@testable import Minidisc

private actor HomeFeedSource: PlaylistBrowsing, RecentlyAddedAlbumBrowsing, ListeningHistoryBrowsing, GenreBrowsing {
    private let failHistory: Bool
    private let waitForGenres: Bool
    private var genreWaiter: CheckedContinuation<Void, Never>?
    private(set) var calls = 0
    var waiting: Bool { genreWaiter != nil }

    init(failHistory: Bool = false, waitForGenres: Bool = false) {
        self.failHistory = failHistory
        self.waitForGenres = waitForGenres
    }
    func playlists() async throws -> [Playlist] {
        calls += 1
        return [Playlist(id: "p", name: "Saved", songCount: 1, duration: 100)]
    }
    func playlist(id: String) async throws -> PlaylistWithSongs { throw URLError(.unsupportedURL) }
    func recentlyAddedAlbums(size: Int) async throws -> [AlbumID3] {
        calls += 1
        return [try JSONDecoder().decode(AlbumID3.self, from: Data(#"{"id":"a","name":"Album","songCount":1,"duration":100}"#.utf8))]
    }
    func recentlyPlayedAlbums(size: Int) async throws -> [AlbumID3] {
        calls += 1
        if failHistory { throw URLError(.timedOut) }
        return []
    }
    func mostPlayedAlbums(size: Int) async throws -> [AlbumID3] { [] }
    func genres() async throws -> [Genre] {
        calls += 1
        if waitForGenres { await withCheckedContinuation { genreWaiter = $0 } }
        return []
    }
    func albumsByGenre(_ genre: String, size: Int) async throws -> [AlbumID3] { [] }
    func release() { genreWaiter?.resume(); genreWaiter = nil }
}

@Suite @MainActor
struct HomeFeedContinuityTests {
    @Test func aSlowGenreDoesNotBlockAlbumsAndAHistoryFailureKeepsOtherSections() async throws {
        let source = HomeFeedSource(failHistory: true, waitForGenres: true)
        let model = HomeFeedViewModel(libraryService: source)
        let load = Task { await model.load() }
        let deadline = ContinuousClock.now + .seconds(3)
        while (!(await source.waiting) || model.recentlyAdded.isEmpty), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.recentlyAdded.map(\.id) == ["a"])
        #expect(model.isLoading)
        await source.release()
        await load.value
        #expect(model.topPicks.map(\.id) == ["p"])
        #expect(model.hasPartialFailure)
        #expect(!model.isEmpty)
    }

    @Test func homeSurvivesRelaunchOfflineAndIsScopedToItsServer() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = HomeFeedSource()
        let serverID = UUID()
        let cache = HomeFeedCache(directory: directory)
        let online = HomeFeedViewModel(libraryService: source, cache: cache, serverID: serverID)
        await online.load()
        let calls = await source.calls
        let offline = HomeFeedViewModel(libraryService: source, cache: HomeFeedCache(directory: directory), serverID: serverID)
        await offline.load(isOnline: false)
        #expect(offline.topPicks.map(\.id) == ["p"])
        #expect(offline.recentlyAdded.map(\.id) == ["a"])
        #expect(await source.calls == calls)
        #expect(await cache.load(serverID: UUID()) == nil)
    }

    @Test func cancellingALoadPreservesVisibleContent() async throws {
        let source = HomeFeedSource(waitForGenres: true)
        let model = HomeFeedViewModel(libraryService: source)
        let load = Task { await model.load() }
        let deadline = ContinuousClock.now + .seconds(3)
        while (!(await source.waiting) || model.recentlyAdded.isEmpty), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        load.cancel()
        await source.release()
        await load.value
        #expect(model.recentlyAdded.map(\.id) == ["a"])
        #expect(!model.isLoading)
        #expect(model.error == nil)
    }
}
