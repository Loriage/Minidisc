import Observation
import OSLog
import SwiftSonic

@Observable
@MainActor
final class AlbumListViewModel {
    var albums: [AlbumID3] = []
    var isLoading = false
    var error: UserFacingError?

    private let libraryService: any LibraryServiceProtocol

    init(libraryService: any LibraryServiceProtocol) {
        self.libraryService = libraryService
    }

    func load() async {
        Logger.boot.notice("🟣 AlbumListViewModel.load() called")
        isLoading = true
        error = nil
        do {
            let result = try await libraryService.allAlbums()
            Logger.boot.notice("🟣 allAlbums() returned \(result.count, privacy: .public) items")
            albums = result
        } catch {
            Logger.boot.error("🔴 allAlbums() failed: \(error, privacy: .public)")
            self.error = UserFacingError.from(error)
        }
        isLoading = false
    }
}
