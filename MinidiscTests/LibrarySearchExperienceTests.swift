import Foundation
import Testing
import SwiftSonic
@testable import Minidisc

@Suite("Library search relevance and continuity")
@MainActor
struct LibrarySearchExperienceTests {
    @Test("An exact song title outranks an artist prefix and an album substring")
    func exactResultFirst() throws {
        let results = try decode("""
        {"artist":[{"id":"a","name":"Lifehouse","albumCount":2}],
         "album":[{"id":"b","name":"A Day in the Life","songCount":1,"duration":180}],
         "song":[{"id":"c","title":"Life","isDir":false}]}
        """)
        let matches = LibrarySearchRanking.matches(query: "life", results: results, playlists: [])
        #expect(matches.first?.id == "song:c")
        #expect(matches.count == 3)
    }

    @Test("Artist and title tokens match regardless of order, case and accents")
    func combinedTokens() throws {
        let results = try decode("""
        {"song":[{"id":"c","title":"Jóga","artist":"Björk","isDir":false}]}
        """)
        let match = try #require(LibrarySearchRanking.matches(query: "BJORK joga", results: results, playlists: []).first)
        #expect(LibrarySearchRanking.score(match, query: "joga bjork") > 0)
    }

    @Test("Playlists are searchable by name and description, scoped separately from catalogue ids")
    func playlistMatches() throws {
        let playlists = [
            Playlist(id: "1", name: "Café du matin", songCount: 8, duration: 1200),
            Playlist(id: "2", name: "Evening", songCount: 4, duration: 500, comment: "Soft jazz"),
            Playlist(id: "3", name: "Metal", songCount: 5, duration: 1200)
        ]
        #expect(LibrarySearchRanking.matches(query: "cafe", results: nil, playlists: playlists).map(\.id) == ["playlist:1"])
        #expect(LibrarySearchRanking.matches(query: "jazz", results: nil, playlists: playlists).map(\.id) == ["playlist:2"])
        #expect(LibrarySearchRanking.matches(query: " ", results: nil, playlists: playlists).isEmpty)
    }

    @Test("Duplicate server results do not create duplicate row identities")
    func duplicateResults() throws {
        let results = try decode("""
        {"song":[{"id":"c","title":"Life","isDir":false},{"id":"c","title":"Life","isDir":false}]}
        """)
        #expect(LibrarySearchRanking.matches(query: "life", results: results, playlists: []).count == 1)
    }

    @Test("A late request cannot overwrite the newer result even if the service ignores cancellation")
    func lateResultIsDiscarded() async throws {
        let service = ControlledSearch()
        let vm = makeViewModel(service)
        let old = Task { await vm.search(query: "old") }
        await service.started("old")
        let new = Task { await vm.search(query: "new") }
        await service.started("new")
        service.finish("new", results: try decode("{}"))
        await new.value
        service.finish("old", results: try decode("{}"))
        await old.value
        #expect(vm.resultsQuery == "new")
        #expect(!vm.isSearching)
    }

    @Test("Existing results remain available and an older completion cannot hide the new loading state")
    func resultsRemainWhileUpdating() async throws {
        let service = ControlledSearch()
        let vm = makeViewModel(service)
        vm.searchResults = try decode("{\"song\":[{\"id\":\"saved\",\"title\":\"Saved\",\"isDir\":false}]}")
        let old = Task { await vm.search(query: "old") }
        await service.started("old")
        let new = Task { await vm.search(query: "new") }
        await service.started("new")
        #expect(vm.searchResults?.song?.first?.id == "saved")
        service.finish("old", results: try decode("{}"))
        await old.value
        #expect(vm.isSearching)
        #expect(vm.searchResults?.song?.first?.id == "saved")
        service.finish("new", results: try decode("{}"))
        await new.value
        #expect(!vm.isSearching)
    }

    private func decode(_ json: String) throws -> SearchResult3 {
        try JSONDecoder().decode(SearchResult3.self, from: Data(json.utf8))
    }

    private func makeViewModel(_ service: ControlledSearch) -> SearchViewModel {
        let state = ServerState()
        state.isOnline = true
        return SearchViewModel(libraryService: service, serverState: state, debounce: .zero)
    }
}

@MainActor
private final class ControlledSearch: LibrarySearching {
    private var pending: [String: CheckedContinuation<SearchResult3, Never>] = [:]
    private var waiters: [String: CheckedContinuation<Void, Never>] = [:]

    @MainActor
    func search(_ query: String) async throws -> SearchResult3 {
        await withCheckedContinuation { continuation in
            pending[query] = continuation
            waiters.removeValue(forKey: query)?.resume()
        }
    }

    func started(_ query: String) async {
        if pending[query] != nil { return }
        await withCheckedContinuation { waiters[query] = $0 }
    }

    func finish(_ query: String, results: SearchResult3) {
        pending.removeValue(forKey: query)?.resume(returning: results)
    }
}
