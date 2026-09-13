import Foundation
import SwiftSonic

@Observable
@MainActor
final class PlaylistListViewModel {
    var playlists: [Playlist] = []
    var isLoading = false
    var error: UserFacingError?

    private let libraryService: any PlaylistBrowsing & RecentlyAddedAlbumBrowsing & StarredBrowsing

    init(libraryService: any PlaylistBrowsing & RecentlyAddedAlbumBrowsing & StarredBrowsing) {
        self.libraryService = libraryService
    }

    var bestOfPlaylists: [ArtistBestOf] = []

    /// The newest album supplies the virtual playlist cover without fetching all its tracks.
    var newestAlbum: AlbumID3?

    /// Failure hides only Recently Added, leaving the main playlist list available.
    func loadRecentlyAdded() async {
        newestAlbum = (try? await libraryService.recentlyAddedAlbums(size: 1))?.first
    }

    /// Failure hides only derived best-of playlists, leaving the server playlist list available.
    func loadBestOf() async {
        guard let starred = try? await libraryService.getStarred2() else {
            bestOfPlaylists = []
            return
        }
        bestOfPlaylists = ArtistBestOf.all(in: starred.song ?? [])
    }

    func load() async {
        isLoading = true
        error = nil
        do {
            playlists = try await libraryService.playlists()
        } catch {
            self.error = UserFacingError.from(error)
        }
        isLoading = false
    }
}
