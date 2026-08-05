import Testing
import Foundation
import SwiftSonic
@testable import Minidisc

// MARK: - Stub

/// Serves a canned newest-album list and per-album track lists. Albums missing from `tracksPerAlbum`
/// throw, standing in for one the server can't open.
private nonisolated final class RALibraryStub: LibraryServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _albumFetches: [String] = []
    private var _listSizes: [Int] = []

    /// The newest-first album list `recentlyAddedAlbums` answers with.
    var newestAlbums: [AlbumID3] = []
    /// Tracks per album id. An absent id makes `album(id:)` throw.
    var tracksPerAlbum: [String: [Song]] = [:]
    /// When true the album LIST itself fails — the one error that must not be swallowed.
    var listFails = false

    var albumFetches: [String] { lock.withLock { _albumFetches } }
    var listSizes: [Int] { lock.withLock { _listSizes } }

    func recentlyAddedAlbums(size: Int) async throws -> [AlbumID3] {
        lock.withLock { _listSizes.append(size) }
        if listFails { throw URLError(.notConnectedToInternet) }
        return Array(newestAlbums.prefix(size))
    }

    func album(id: String) async throws -> AlbumID3 {
        lock.withLock { _albumFetches.append(id) }
        guard let songs = tracksPerAlbum[id] else { throw URLError(.badServerResponse) }
        return album(id: id, songs: songs)
    }

    private func album(id: String, songs: [Song]) -> AlbumID3 {
        AlbumID3(id: id, name: id, songCount: songs.count, duration: 0, coverArt: "cover-\(id)", song: songs)
    }

    // Unused by the recently-added composition.
    func artists() async throws -> [ArtistIndex] { throw URLError(.unknown) }
    func artist(id: String) async throws -> ArtistID3 { throw URLError(.unknown) }
    func fetchAllTracks(forArtistID artistID: String) async throws -> [DisplayableSong] { [] }
    func playlists() async throws -> [Playlist] { [] }
    func playlist(id: String) async throws -> PlaylistWithSongs { throw URLError(.unknown) }
    func search(_ query: String) async throws -> SearchResult3 { throw URLError(.unknown) }
    func coverArtURL(id: String, size: Int?) async -> URL? { nil }
    func streamURL(songId: String) async -> URL? { nil }
    func star(songIds: [String], albumIds: [String], artistIds: [String]) async throws {}
    func unstar(songIds: [String], albumIds: [String], artistIds: [String]) async throws {}
    func getStarred2() async throws -> Starred2 { throw URLError(.unknown) }
    func allAlbums() async throws -> [AlbumID3] { [] }
    func allSongs(offset: Int, count: Int) async throws -> [Song] { [] }
    func scrobble(songId: String, submission: Bool) async {}
    func recentlyPlayedAlbums(size: Int) async throws -> [AlbumID3] { [] }
    func mostPlayedAlbums(size: Int) async throws -> [AlbumID3] { [] }
    func randomSongs(size: Int) async throws -> [Song] { [] }
    func songsByGenre(_ genre: String, count: Int) async throws -> [Song] { [] }
    func smartShuffleQueue(targetSize: Int) async throws -> [DisplayableSong] { [] }
    func similarBackfillQueue(targetSize: Int, excludedIds: Set<String>) async throws -> [DisplayableSong] { [] }
    func getArtistInfo(forArtistID artistID: String, count: Int) async throws -> ArtistInfo { throw URLError(.unknown) }
    func getArtistMBID(forArtistID artistID: String) async throws -> String? { nil }
    func findArtist(byName name: String) async -> ArtistID3? { nil }
    func topSongs(artist: String, count: Int) async throws -> [DisplayableSong] { [] }
    func instantMix(from seed: InstantMixSeed, count: Int) async throws -> [DisplayableSong] { [] }
}

private func track(_ id: String) -> Song {
    Song(id: id, title: "Track \(id)")
}

private func newest(_ ids: [String]) -> [AlbumID3] {
    ids.map { AlbumID3(id: $0, name: $0, songCount: 0, duration: 0, coverArt: "cover-\($0)") }
}

// MARK: - Assembly

@Suite("Recently Added — track assembly")
struct RecentlyAddedAssemblyTests {

    @Test("albums that finished out of order are put back in newest-first order")
    func albumOrderIsRestored() {
        // The fetches run concurrently, so the collected entries arrive in whatever order the server
        // answered — only the carried index says which album was newest.
        let collected: [(index: Int, songs: [Song])] = [
            (index: 2, songs: [track("c1")]),
            (index: 0, songs: [track("a1"), track("a2")]),
            (index: 1, songs: [track("b1")]),
        ]

        #expect(RecentlyAdded.tracks(from: collected).map(\.id) == ["a1", "a2", "b1", "c1"])
    }

    @Test("a track listed under two albums plays once, at its earliest position")
    func duplicatesAreDropped() {
        let shared = track("dup")
        let collected: [(index: Int, songs: [Song])] = [
            (index: 0, songs: [shared, track("a2")]),
            (index: 1, songs: [shared, track("b2")]),
        ]

        #expect(RecentlyAdded.tracks(from: collected).map(\.id) == ["dup", "a2", "b2"])
    }

    @Test("the limit truncates mid-album rather than dropping the album")
    func limitTruncates() {
        let collected: [(index: Int, songs: [Song])] = [
            (index: 0, songs: [track("a1"), track("a2")]),
            (index: 1, songs: [track("b1"), track("b2")]),
        ]

        #expect(RecentlyAdded.tracks(from: collected, limit: 3).map(\.id) == ["a1", "a2", "b1"])
        #expect(RecentlyAdded.tracks(from: collected, limit: 0).isEmpty)
    }
}

// MARK: - Service composition

@Suite("Recently Added — library composition")
struct RecentlyAddedLibraryTests {

    @Test("the newest albums' tracks arrive as one album-ordered list")
    func tracksFollowAlbumOrder() async throws {
        let library = RALibraryStub()
        library.newestAlbums = newest(["newest", "older", "oldest"])
        library.tracksPerAlbum = [
            "newest": [track("n1"), track("n2")],
            "older": [track("o1")],
            "oldest": [track("z1")],
        ]

        let tracks = try await library.recentlyAddedTracks(albumLimit: 10, trackLimit: 100)

        #expect(tracks.map(\.id) == ["n1", "n2", "o1", "z1"])
        #expect(library.listSizes == [10], "the album limit is what the server is asked for")
        #expect(Set(library.albumFetches) == ["newest", "older", "oldest"])
    }

    @Test("an album the server can't open costs its own tracks, not the list")
    func oneFailingAlbumIsSkipped() async throws {
        let library = RALibraryStub()
        library.newestAlbums = newest(["newest", "broken", "oldest"])
        library.tracksPerAlbum = [
            "newest": [track("n1")],
            "oldest": [track("z1")],
        ]

        let tracks = try await library.recentlyAddedTracks(albumLimit: 10, trackLimit: 100)

        #expect(tracks.map(\.id) == ["n1", "z1"], "the gap must not reorder what survived")
    }

    @Test("a failing album LIST throws — there is nothing to show and no partial answer to give")
    func listFailurePropagates() async {
        let library = RALibraryStub()
        library.listFails = true

        await #expect(throws: URLError.self) {
            try await library.recentlyAddedTracks(albumLimit: 10, trackLimit: 100)
        }
    }

    @Test("an empty library opens no album")
    func emptyLibraryFetchesNothing() async throws {
        let library = RALibraryStub()

        #expect(try await library.recentlyAddedTracks(albumLimit: 10, trackLimit: 100).isEmpty)
        #expect(library.albumFetches.isEmpty)
    }

    @Test("the track limit caps the assembled list")
    func trackLimitApplies() async throws {
        let library = RALibraryStub()
        library.newestAlbums = newest(["newest", "older"])
        library.tracksPerAlbum = [
            "newest": [track("n1"), track("n2")],
            "older": [track("o1")],
        ]

        let tracks = try await library.recentlyAddedTracks(albumLimit: 10, trackLimit: 2)

        #expect(tracks.map(\.id) == ["n1", "n2"])
    }

    @Test("more albums than the in-flight ceiling are all fetched")
    func everyAlbumIsFetchedBeyondTheConcurrencyWindow() async throws {
        // 5 fetches run at once; the rest are submitted as earlier ones land. A bug in that refill loop
        // would silently truncate the playlist to the first window.
        let ids = (0..<12).map { "album-\($0)" }
        let library = RALibraryStub()
        library.newestAlbums = newest(ids)
        library.tracksPerAlbum = Dictionary(uniqueKeysWithValues: ids.map { ($0, [track("t-\($0)")]) })

        let tracks = try await library.recentlyAddedTracks(albumLimit: 20, trackLimit: 100)

        #expect(tracks.map(\.id) == ids.map { "t-\($0)" })
        #expect(library.albumFetches.count == 12)
    }
}
