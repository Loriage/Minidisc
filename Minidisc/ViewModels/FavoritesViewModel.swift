import Foundation
import SwiftSonic

@Observable
@MainActor
final class FavoritesViewModel {
    var songs: [Song] = []
    var albums: [AlbumID3] = []
    var artists: [ArtistID3] = []
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
            let starred = try await libraryService.getStarred2()
            songs = starred.song ?? []
            albums = starred.album ?? []
            artists = starred.artist ?? []
        } catch {
            self.error = UserFacingError.from(error)
        }
        isLoading = false
    }
}
