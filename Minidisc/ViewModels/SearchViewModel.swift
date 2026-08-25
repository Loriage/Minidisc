import Foundation
import SwiftSonic

@Observable
@MainActor
final class SearchViewModel {
    /// Quiet period between the last keystroke and the actual server request.
    /// SearchView's `.task(id: query)` cancels the previous call on every change,
    /// so only the final query survives this delay.
    static let searchDebounce: Duration = .milliseconds(300)

    var searchResults: SearchResult3?
    var isSearching = false
    var searchError: UserFacingError?
    /// True only when neither the persistent catalogue index nor the server could answer,
    /// so the view falls back to downloaded tracks.
    var isOffline = false

    private let libraryService: any LibrarySearching
    private let serverState: ServerState

    init(libraryService: any LibrarySearching, serverState: ServerState) {
        self.libraryService = libraryService
        self.serverState = serverState
    }

    func search(query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            // Cleared query: drop stale state immediately — no request, no debounce wait.
            searchResults = nil
            searchError = nil
            isSearching = false
            isOffline = false
            return
        }
        isOffline = false
        do {
            try await Task.sleep(for: Self.searchDebounce)
            // Spinner reflects the actual in-flight request, not the debounce wait.
            isSearching = true
            searchError = nil
            defer { isSearching = false }
            let results = try await libraryService.search(trimmed)
            // Superseded between response and assignment — let the newer query win.
            try Task.checkCancellation()
            searchResults = results
        } catch where Self.isCancellation(error) {
            // Superseded by a newer query — not a user-facing error.
        } catch {
            if serverState.isOnline {
                searchError = UserFacingError.from(error)
            } else {
                searchResults = nil
                searchError = nil
                isOffline = true
            }
        }
    }

    /// True for task cancellation or a cancelled in-flight request — whether the
    /// URLError -999 surfaces raw or wrapped in `SwiftSonicError.network`.
    private static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        if let sse = error as? SwiftSonicError, case .network(let urlError) = sse, urlError.code == .cancelled { return true }
        return false
    }
}
