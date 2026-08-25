import Testing
import Foundation
import SwiftSonic
@testable import Minidisc

/// Library stub for the mood providers. Internal so the sonic provider's tests can reuse it for
/// the by-name resolution path.
actor TagLibraryStub: LibrarySearching, MoodTrackSourcing {
    private var _genreQueries: [String] = []
    private var _randomCalls = 0

    /// Songs returned per genre. Absent genres return empty, like a real server.
    var songsPerGenre: [String: [Song]] = [:]
    var randomPool: [Song] = []
    /// Songs returned by `search`, used by SubsonicTrackResolver.
    var searchResults: [Song] = []
    private var _searches: [String] = []
    var searches: [String] { _searches }

    var genreQueries: [String] { _genreQueries }
    var randomCalls: Int { _randomCalls }

    func setSongs(_ songs: [Song], forGenre genre: String) { songsPerGenre[genre] = songs }
    func setRandomPool(_ songs: [Song]) { randomPool = songs }
    func setSearchResults(_ songs: [Song]) { searchResults = songs }

    func songsByGenre(_ genre: String, count: Int) async throws -> [Song] {
        _genreQueries.append(genre)
        return songsPerGenre[genre] ?? []
    }

    func randomSongs(size: Int) async throws -> [Song] {
        _randomCalls += 1
        return randomPool
    }

    /// Used by SubsonicTrackResolver when the sonic provider falls back to matching by name.
    func search(_ query: String) async throws -> SearchResult3 {
        _searches.append(query)
        let songs = searchResults.map {
            #"{"id":"\#($0.id)","title":"\#($0.title)","artist":"\#($0.artist ?? "")","isDir":false}"#
        }
        return try JSONDecoder().decode(SearchResult3.self, from: Data(#"{"song":[\#(songs.joined(separator: ","))]}"#.utf8))
    }
}

/// Song is Decodable-only, so fixtures are built from JSON.
func song(id: String, title: String = "T", artist: String? = nil, genre: String? = nil, bpm: Int? = nil, moods: [String] = []) throws -> Song {
    var fields: [String] = [#""id":"\#(id)""#, #""title":"\#(title)""#, #""isDir":false"#]
    if let artist { fields.append(#""artist":"\#(artist)""#) }
    if let genre { fields.append(#""genre":"\#(genre)""#) }
    if let bpm { fields.append(#""bpm":\#(bpm)"#) }
    if !moods.isEmpty {
        fields.append(#""moods":[\#(moods.map { #""\#($0)""# }.joined(separator: ","))]"#)
    }
    return try JSONDecoder().decode(Song.self, from: Data("{\(fields.joined(separator: ","))}".utf8))
}

@Suite("Mood playlists — tag provider candidate sourcing")
struct LibraryTagTrackProviderTests {

    @Test("genres present in the library are used directly")
    func genresAreUsedWhenPresent() async throws {
        let library = TagLibraryStub()
        await library.setSongs([try song(id: "a", genre: "Dance", bpm: 130)], forGenre: "dance")
        let provider = LibraryTagTrackProvider(libraryService: library)

        let ids = try await provider.trackIds(for: .energetic, limit: 10)

        #expect(ids == ["a"])
        #expect(await library.randomCalls == 0, "no need for the broad pool when genres answered")
    }

    @Test("a library with none of a mood's genres falls back to a broad sample")
    func emptyGenresFallBackToRandomPool() async throws {
        // The case a real library hit: French rap, so Night's ambient/jazz/classical genres are all
        // absent and every genre query comes back empty. Before the fallback this produced nothing
        // at all, every week, forever.
        let library = TagLibraryStub()
        await library.setRandomPool([
            try song(id: "slow", bpm: 70),
            try song(id: "fast", bpm: 175),
        ])
        let provider = LibraryTagTrackProvider(libraryService: library)

        let ids = try await provider.trackIds(for: .night, limit: 10)

        #expect(await library.randomCalls == 1)
        #expect(ids == ["slow"], "BPM alone should still separate a night track from a fast one")
    }

    @Test("the broad sample uses MOOD tags when there is no BPM")
    func fallbackUsesMoodTags() async throws {
        let library = TagLibraryStub()
        await library.setRandomPool([
            try song(id: "calm", moods: ["Calm"]),
            try song(id: "angry", moods: ["Aggressive"]),
        ])
        let provider = LibraryTagTrackProvider(libraryService: library)

        #expect(try await provider.trackIds(for: .night, limit: 10) == ["calm"])
        #expect(try await provider.trackIds(for: .workout, limit: 10) == ["angry"])
    }

    @Test("an untagged library yields nothing rather than something arbitrary")
    func untaggedLibraryYieldsNothing() async throws {
        let library = TagLibraryStub()
        await library.setRandomPool([try song(id: "a"), try song(id: "b")])
        let provider = LibraryTagTrackProvider(libraryService: library)

        // Empty is the correct answer: the sync treats it as a skip and leaves the previous
        // playlist untouched, rather than filling it with music chosen at random.
        #expect(try await provider.trackIds(for: .chill, limit: 10).isEmpty)
    }

    @Test("every one of a mood's genres is queried")
    func allGenresAreQueried() async throws {
        let library = TagLibraryStub()
        let provider = LibraryTagTrackProvider(libraryService: library)

        _ = try await provider.trackIds(for: .workout, limit: 10)

        #expect(await library.genreQueries == MoodTagMatcher.genres(.workout))
    }

    @Test("a track appearing under two of a mood's genres is only counted once")
    func duplicatesAreDeduped() async throws {
        let library = TagLibraryStub()
        let shared = try song(id: "dup", genre: "Ambient", bpm: 80)
        await library.setSongs([shared], forGenre: "ambient")
        await library.setSongs([shared], forGenre: "classical")
        let provider = LibraryTagTrackProvider(libraryService: library)

        #expect(try await provider.trackIds(for: .night, limit: 10) == ["dup"])
    }
}
