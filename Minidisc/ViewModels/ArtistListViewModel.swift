import Foundation
import SwiftSonic

@Observable
@MainActor
final class ArtistListViewModel {
    var indexes: [ArtistIndex] = []
    var isLoading = false
    var error: UserFacingError?

    private let libraryService: any LibraryServiceProtocol

    init(libraryService: any LibraryServiceProtocol) {
        self.libraryService = libraryService
    }

    func load() async {
        isLoading = true
        error = nil
        do {
            indexes = try await libraryService.artists()
        } catch {
            self.error = UserFacingError.from(error)
        }
        isLoading = false
    }
}
