import Foundation
import SwiftSonic
import Testing
@testable import Minidisc

private enum LibraryStubBehavior: Sendable {
    case cancellation
    case failure
    case songs([DisplayableSong])
}

private enum LibraryStubError: Error {
    case unavailable
}

private actor EndlessExtensionLibraryStub: LibraryServiceProtocol {
    private let instantMixBehavior: LibraryStubBehavior
    private let backfillBehavior: LibraryStubBehavior
    private var backfillCalls = 0

    init(
        instantMixBehavior: LibraryStubBehavior,
        backfillBehavior: LibraryStubBehavior
    ) {
        self.instantMixBehavior = instantMixBehavior
        self.backfillBehavior = backfillBehavior
    }

    func instantMix(from seed: InstantMixSeed, count: Int) async throws -> [DisplayableSong] {
        try Self.resolve(instantMixBehavior)
    }

    func similarBackfillQueue(
        targetSize: Int,
        excludedIds: Set<String>
    ) async throws -> [DisplayableSong] {
        backfillCalls += 1
        return try Self.resolve(backfillBehavior)
    }

    func backfillCallCount() -> Int {
        backfillCalls
    }

    private nonisolated static func resolve(
        _ behavior: LibraryStubBehavior
    ) throws -> [DisplayableSong] {
        switch behavior {
        case .cancellation:
            throw CancellationError()
        case .failure:
            throw LibraryStubError.unavailable
        case .songs(let songs):
            return songs
        }
    }

    func artists() async throws -> [ArtistIndex] { [] }
    func artist(id: String) async throws -> ArtistID3 { throw LibraryStubError.unavailable }
    func album(id: String) async throws -> AlbumID3 { throw LibraryStubError.unavailable }
    func fetchAllTracks(forArtistID artistID: String) async throws -> [DisplayableSong] { [] }
    func playlists() async throws -> [Playlist] { [] }
    func playlist(id: String) async throws -> PlaylistWithSongs { throw LibraryStubError.unavailable }
    func search(_ query: String) async throws -> SearchResult3 { throw LibraryStubError.unavailable }
    func coverArtURL(id: String, size: Int?) async -> URL? { nil }
    func streamURL(songId: String) async -> URL? { nil }
    func star(songIds: [String], albumIds: [String], artistIds: [String]) async throws {}
    func unstar(songIds: [String], albumIds: [String], artistIds: [String]) async throws {}
    func getStarred2() async throws -> Starred2 { throw LibraryStubError.unavailable }
    func recentlyAddedAlbums(size: Int) async throws -> [AlbumID3] { [] }
    func allAlbums() async throws -> [AlbumID3] { [] }
    func allSongs(offset: Int, count: Int) async throws -> [Song] { [] }
    func scrobble(songId: String, submission: Bool) async {}
    func recentlyPlayedAlbums(size: Int) async throws -> [AlbumID3] { [] }
    func mostPlayedAlbums(size: Int) async throws -> [AlbumID3] { [] }
    func randomSongs(size: Int) async throws -> [Song] { [] }
    func songsByGenre(_ genre: String, count: Int) async throws -> [Song] { [] }
    func smartShuffleQueue(targetSize: Int) async throws -> [DisplayableSong] { [] }
    func getArtistInfo(forArtistID artistID: String, count: Int) async throws -> ArtistInfo {
        throw LibraryStubError.unavailable
    }
    func getArtistMBID(forArtistID artistID: String) async throws -> String? { nil }
    func findArtist(byName name: String) async -> ArtistID3? { nil }
    func topSongs(artist: String, count: Int) async throws -> [DisplayableSong] { [] }
}

@Suite("Library cancellation propagation")
struct LibraryCancellationTests {
    @Test("Instant-mix cancellation is not converted into an empty best-effort result")
    func instantMixCancellationPropagates() async {
        let library = EndlessExtensionLibraryStub(
            instantMixBehavior: .cancellation,
            backfillBehavior: .songs([])
        )

        await #expect(throws: CancellationError.self) {
            try await library.endlessExtension(
                seedTrackId: "seed",
                targetSize: 20,
                excludedIds: []
            )
        }
        #expect(await library.backfillCallCount() == 0)
    }

    @Test("Backfill cancellation is not swallowed after an ordinary instant-mix failure")
    func backfillCancellationPropagates() async {
        let library = EndlessExtensionLibraryStub(
            instantMixBehavior: .failure,
            backfillBehavior: .cancellation
        )

        await #expect(throws: CancellationError.self) {
            try await library.endlessExtension(
                seedTrackId: "seed",
                targetSize: 20,
                excludedIds: []
            )
        }
        #expect(await library.backfillCallCount() == 1)
    }

    @Test("Ordinary provider failures retain best-effort fallback semantics")
    func ordinaryFailuresRemainBestEffort() async throws {
        let library = EndlessExtensionLibraryStub(
            instantMixBehavior: .failure,
            backfillBehavior: .failure
        )

        let result = try await library.endlessExtension(
            seedTrackId: "seed",
            targetSize: 20,
            excludedIds: []
        )

        #expect(result.isEmpty)
        #expect(await library.backfillCallCount() == 1)
    }
}
