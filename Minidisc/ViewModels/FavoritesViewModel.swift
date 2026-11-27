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

    private let libraryService: any StarredBrowsing
    private var generation = 0

    init(libraryService: any StarredBrowsing) {
        self.libraryService = libraryService
    }

    func load() async {
        generation += 1
        let request = generation
        isLoading = true
        error = nil
        defer { if request == generation { isLoading = false } }
        do {
            let starred = try await libraryService.getStarred2()
            try Task.checkCancellation()
            guard request == generation else { return }
            songs = starred.song ?? []
            albums = starred.album ?? []
            artists = starred.artist ?? []
        } catch {
            guard request == generation, !UserFacingError.isCancellation(error) else { return }
            self.error = UserFacingError.from(error)
        }
    }
}
