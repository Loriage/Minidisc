import Foundation
import SwiftSonic
import Testing
@testable import Minidisc

@Suite("CarPlay library")
@MainActor
struct CarPlayLibraryTests {
    @Test func builtAppRegistersTheCarPlayScene() throws {
        // Xcode's automatic scene-manifest generation can overwrite the source plist.
        let manifest = try #require(Bundle.main.infoDictionary?["UIApplicationSceneManifest"] as? [String: Any])
        let configurations = try #require(manifest["UISceneConfigurations"] as? [String: Any])
        let carPlay = try #require(configurations["CPTemplateApplicationSceneSessionRoleApplication"] as? [[String: Any]])
        let scene = try #require(carPlay.first)
        #expect(scene["UISceneClassName"] as? String == "CPTemplateApplicationScene")
        let delegate = try #require(scene["UISceneDelegateClassName"] as? String)
        #expect(NSClassFromString(delegate) === CarPlaySceneDelegate.self)
        #expect(manifest["UIApplicationSupportsMultipleScenes"] as? Bool == true)
    }

    @Test func localOnlyLaunchNeverRequiresAServerAndExcludesMissingFiles() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = Source()
        let library = CarPlayLibrary(server: ServerState(), source: source, localStore: fixture.store,
                                     readOffline: { _ in Issue.record("No server must not read a server cache"); return .init() })
        let songs = try await library.load(.songs)
        #expect(songs.songs.map(\.id) == [fixture.available.id])
        let albums = try await library.load(.albums)
        #expect(albums.collections.count == 1)
        let album = try await library.load(try #require(albums.collections.first).route)
        #expect(album.songs.first?.localFile == fixture.available.song.localFile)
        #expect(await source.calls == 0)
    }

    @Test func onlineLibraryMergesSourcesAndRetainsLocalPlaybackReferences() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let state = configuredServer()
        let library = CarPlayLibrary(server: state, source: Source(), localStore: fixture.store, readOffline: { _ in .init() })
        let content = try await library.load(.songs)
        #expect(content.songs.map(\.title) == ["Local", "Server"])
        let queue = try await library.preparePlayback(content, index: 0)
        #expect(queue.tracks.count == 2)
        #expect(queue.tracks.first?.localFile == fixture.available.song.localFile)
        #expect(queue.startIndex == 0)
    }

    @Test func offlinePlaylistUsesOnlyPlayableFilesAndPreservesDuplicates() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let state = configuredServer()
        state.isOnline = false
        let source = Source()
        let snapshot = OfflineBrowsingSnapshot(songs: [DisplayableSong(from: Song(id: "one", title: "One"))],
            playlists: [Playlist(id: "list", name: "List", songCount: 3, duration: 60)],
            membership: ["list": ["one", "missing", "one"]])
        let library = CarPlayLibrary(server: state, source: source, localStore: fixture.store, readOffline: { _ in snapshot })
        let content = try await library.load(.playlist("list"))
        #expect(content.songs.map(\.id) == ["one", "one"])
        let queue = try await library.preparePlayback(content, index: 1)
        #expect(queue.startIndex == 1)
        #expect(queue.tracks.map(\.id) == ["one", "one"])
        #expect(await source.calls == 0)
    }

    @Test func lateResultFromPreviousConnectionIsDiscarded() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let state = configuredServer()
        state.isOnline = false
        let library = CarPlayLibrary(server: state, source: Source(), localStore: fixture.store, readOffline: { _ in
            await MainActor.run { state.activeConnectionVersion = .init(serverID: state.activeServer!.id, revision: 2) }
            return OfflineBrowsingSnapshot(songs: [DisplayableSong(from: Song(id: "old", title: "Old account"))])
        })
        await #expect(throws: CancellationError.self) { try await library.load(.songs) }
    }

    @Test func selectionCannotCrossServerOrOfflineModeChanges() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let state = configuredServer()
        let library = CarPlayLibrary(server: state, source: Source(), localStore: fixture.store, readOffline: { _ in .init() })
        let content = try await library.load(.songs)
        state.isOnline = false
        await #expect(throws: CancellationError.self) { try await library.preparePlayback(content, index: 0) }
        state.isOnline = true
        state.activeConnectionVersion = .init(serverID: state.activeServer!.id, revision: 2)
        await #expect(throws: CancellationError.self) { try await library.preparePlayback(content, index: 0) }
    }

    @Test func removedLocalFolderInvalidatesAnAlreadyDisplayedSelection() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let library = CarPlayLibrary(server: ServerState(), source: Source(), localStore: fixture.store, readOffline: { _ in .init() })
        let content = try await library.load(.songs)
        try await fixture.store.remove(fixture.available.song.localFile!.folderID)
        await #expect(throws: LocalMusicError.unavailable) { try await library.preparePlayback(content, index: 0) }
    }

    @Test func serverFailureKeepsLocalMusicUsableAndSignalsFallback() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let library = CarPlayLibrary(server: configuredServer(), source: Source(error: URLError(.notConnectedToInternet)),
                                     localStore: fixture.store, readOffline: { _ in .init() })
        let content = try await library.load(.songs)
        #expect(content.showingOfflineFallback)
        #expect(content.songs.map(\.id) == [fixture.available.id])
    }

    @Test func cancellationDoesNotBecomeAnEmptyOrOfflineResult() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let library = CarPlayLibrary(server: configuredServer(), source: Source(error: CancellationError()),
                                     localStore: fixture.store, readOffline: { _ in Issue.record("Cancelled load must stop"); return .init() })
        await #expect(throws: CancellationError.self) { try await library.load(.songs) }
    }

    @Test func playbackRetainsTheWholeCollectionBeyondTheDisplayLimit() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let library = CarPlayLibrary(server: configuredServer(), source: Source(), localStore: fixture.store, readOffline: { _ in .init() })
        let songs = (0..<800).map { DisplayableSong(from: Song(id: "\($0)", title: "Song \($0)")) }
        let content = CarPlayContent(context: library.context, songs: songs)
        let queue = try await library.preparePlayback(content, index: 799, shuffled: true)
        #expect(queue.tracks.count == 800)
        #expect(queue.startIndex == 799)
        #expect(queue.tracks.last?.id == "799")
        if case .shuffled = queue.order {} else { Issue.record("Shuffle must be committed by the player") }
    }

    @Test func songPagesReachBeyondCarPlayListLimitsWithoutRepeatingLocalFiles() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = Source(songs: (0..<5).map { Song(id: "\($0)", title: "Server \($0)") })
        let library = CarPlayLibrary(server: configuredServer(), source: source,
                                     localStore: fixture.store, readOffline: { _ in .init() })
        let first = try await library.load(.songs, songLimit: 2)
        #expect(first.songs.count == 3)
        #expect(first.previousPage == nil)
        let second = try await library.load(try #require(first.nextPage), songLimit: 2)
        #expect(second.songs.map(\.id) == ["2", "3"])
        #expect(second.previousPage == .songs)
        let last = try await library.load(try #require(second.nextPage), songLimit: 2)
        #expect(last.songs.map(\.id) == ["4"])
        #expect(last.nextPage == nil)
        #expect(last.previousPage == .songPage(offset: 2))
    }

    private func configuredServer() -> ServerState {
        let state = ServerState()
        let config = ServerConfig(displayName: "Fixture", baseURL: "https://music.example", username: "test")
        state.activeServer = ServerSnapshot(from: config)
        state.activeConnectionVersion = .init(serverID: config.id, revision: 1)
        return state
    }

    private struct Fixture {
        let root: URL
        let store: LocalMusicStore
        let available: LocalMusicTrack
        init() throws {
            root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var track = LocalMusicStore.placeholder(.init(folderID: UUID(), relativePath: "Local.wav"))
            track.isAvailable = true
            available = track
            let missing = LocalMusicStore.placeholder(.init(folderID: UUID(), relativePath: "Missing.wav"))
            try JSONEncoder().encode(LocalMusicSnapshot(tracks: [track, missing])).write(to: root.appendingPathComponent("index.json"))
            store = LocalMusicStore(directory: root)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private actor Source: CarPlayLibrarySource {
        var calls = 0
        let error: (any Error)?
        let songs: [Song]
        init(error: (any Error)? = nil, songs: [Song] = [Song(id: "server", title: "Server")]) {
            self.error = error; self.songs = songs
        }
        func allSongs(offset: Int, count: Int) throws -> [Song] {
            calls += 1
            if let error { throw error }
            return Array(songs.dropFirst(offset).prefix(count))
        }
        func allAlbums() -> [AlbumID3] { calls += 1; return [] }
        func album(id: String) throws -> AlbumID3 { calls += 1; throw URLError(.badServerResponse) }
        func artists() -> [ArtistIndex] { calls += 1; return [] }
        func artist(id: String) throws -> ArtistID3 { calls += 1; throw URLError(.badServerResponse) }
        func fetchAllTracks(forArtistID artistID: String) -> [DisplayableSong] { calls += 1; return [] }
        func playlists() -> [Playlist] { calls += 1; return [] }
        func playlist(id: String) throws -> PlaylistWithSongs { calls += 1; throw URLError(.badServerResponse) }
        func recentlyAddedAlbums(size: Int) -> [AlbumID3] { calls += 1; return [] }
        func getStarred2() throws -> Starred2 { calls += 1; throw URLError(.badServerResponse) }
    }
}
