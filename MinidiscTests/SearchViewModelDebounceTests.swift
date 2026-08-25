import Testing
import Foundation
import SwiftSonic
@testable import Minidisc

// MARK: - Counting stub

/// Records `search` calls and replays a configurable outcome.
/// Main-actor test double because the view model and its assertions are UI-isolated.
@MainActor
private final class SearchLibraryStub: LibrarySearching {
    enum Behavior {
        case succeed
        case fail(any Error)
    }

    private(set) var searchCalls: [String] = []
    var behavior: Behavior = .succeed

    @MainActor
    func search(_ query: String) async throws -> SearchResult3 {
        searchCalls.append(query)
        switch behavior {
        case .succeed:
            // SearchResult3 is Decodable-only; all fields are optional so "{}" decodes.
            return try JSONDecoder().decode(SearchResult3.self, from: Data("{}".utf8))
        case .fail(let error):
            throw error
        }
    }

}

// MARK: - Tests

@Suite("SearchViewModel — debounce & cancellation")
@MainActor
struct SearchViewModelDebounceTests {

    /// The debounce tests are all about the online path — offline the VM returns before any request.
    private func onlineState() -> ServerState {
        let state = ServerState()
        state.isOnline = true
        return state
    }

    @Test("rapid query changes call the service once, with the final query")
    func rapidTypingCoalescesToFinalQuery() async throws {
        let stub = SearchLibraryStub()
        let vm = SearchViewModel(libraryService: stub, serverState: onlineState())

        // Emulate SwiftUI's .task(id:) contract: each keystroke cancels the
        // previous call. Cancellation lands during the debounce sleep, well
        // within the quiet period — no wall-clock dependence.
        for partial in ["c", "ca", "cas", "cass"] {
            let superseded = Task { await vm.search(query: partial) }
            superseded.cancel()
            await superseded.value
        }
        await vm.search(query: "minidisc")

        #expect(stub.searchCalls == ["minidisc"])
        #expect(vm.searchError == nil)
        #expect(vm.isSearching == false)
        #expect(vm.searchResults != nil)
    }

    @Test("offline search can be answered by the persistent catalogue index")
    func offlineUsesTheCatalogueIndex() async throws {
        let stub = SearchLibraryStub()
        let state = ServerState()
        state.isOnline = false
        let vm = SearchViewModel(libraryService: stub, serverState: state)

        await vm.search(query: "minidisc")

        #expect(vm.isOffline == false)
        #expect(stub.searchCalls == ["minidisc"])
        #expect(vm.searchResults != nil)
        #expect(vm.searchError == nil)
        #expect(vm.isSearching == false)
    }

    @Test("offline index miss falls back to downloaded tracks")
    func offlineFailureUsesDownloadsFallback() async throws {
        let stub = SearchLibraryStub()
        stub.behavior = .fail(URLError(.notConnectedToInternet))
        let state = ServerState()
        state.isOnline = false
        let vm = SearchViewModel(libraryService: stub, serverState: state)

        await vm.search(query: "minidisc")

        #expect(vm.isOffline)
        #expect(vm.searchResults == nil)
        #expect(vm.searchError == nil)
    }

    @Test("clearing the query drops the offline flag too")
    func clearingQueryResetsOfflineFlag() async throws {
        let stub = SearchLibraryStub()
        stub.behavior = .fail(URLError(.notConnectedToInternet))
        let state = ServerState()
        state.isOnline = false
        let vm = SearchViewModel(libraryService: stub, serverState: state)

        await vm.search(query: "minidisc")
        #expect(vm.isOffline)
        await vm.search(query: "")
        #expect(vm.isOffline == false)
    }

    @Test("coming back online resumes server search")
    func backOnlineResumesServerSearch() async throws {
        let stub = SearchLibraryStub()
        stub.behavior = .fail(URLError(.notConnectedToInternet))
        let state = ServerState()
        state.isOnline = false
        let vm = SearchViewModel(libraryService: stub, serverState: state)

        await vm.search(query: "minidisc")
        #expect(stub.searchCalls == ["minidisc"])

        state.isOnline = true
        stub.behavior = .succeed
        await vm.search(query: "minidisc")

        #expect(vm.isOffline == false)
        #expect(stub.searchCalls == ["minidisc", "minidisc"])
    }

    @Test("empty or whitespace query clears state without any request")
    func emptyQueryClearsWithoutRequest() async throws {
        let stub = SearchLibraryStub()
        let vm = SearchViewModel(libraryService: stub, serverState: onlineState())
        vm.searchResults = try JSONDecoder().decode(SearchResult3.self, from: Data("{}".utf8))
        vm.searchError = .unexpected
        vm.isSearching = true

        await vm.search(query: "   ")

        #expect(vm.searchResults == nil)
        #expect(vm.searchError == nil)
        #expect(vm.isSearching == false)
        #expect(stub.searchCalls.isEmpty)
    }

    @Test("superseded in-flight request is swallowed silently")
    func cancelledRequestIsSilent() async throws {
        let cancellations: [any Error] = [
            CancellationError(),
            URLError(.cancelled),
            SwiftSonicError.network(URLError(.cancelled)),
        ]
        for error in cancellations {
            let stub = SearchLibraryStub()
            stub.behavior = .fail(error)
            let vm = SearchViewModel(libraryService: stub, serverState: onlineState())

            await vm.search(query: "minidisc")

            #expect(vm.searchError == nil, "\(error) must not surface to the UI")
            #expect(vm.isSearching == false)
        }
    }

    @Test("a real failure still surfaces as a user-facing error")
    func realErrorSurfaces() async throws {
        let stub = SearchLibraryStub()
        stub.behavior = .fail(URLError(.timedOut))
        let vm = SearchViewModel(libraryService: stub, serverState: onlineState())

        await vm.search(query: "minidisc")

        #expect(vm.searchError != nil)
        #expect(vm.isSearching == false)
    }
}
