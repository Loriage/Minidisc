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

    /// Virtual "best of" playlists derived from the user's stars — never server playlists, so they are
    /// kept in their own section rather than mixed into `playlists`.
    var bestOfPlaylists: [ArtistBestOf] = []

    /// The newest album in the library. Stands in for the virtual "Recently Added" playlist: its presence
    /// says the playlist has something to show, and its cover dresses the row — both for one cheap call,
    /// where counting the tracks would mean fetching every one of them.
    var newestAlbum: AlbumID3?

    /// Loads the stand-in for the derived "Recently Added" playlist. Non-throwing like `loadBestOf()`:
    /// a server that can't answer should cost the row, not the playlist list.
    func loadRecentlyAdded() async {
        newestAlbum = (try? await libraryService.recentlyAddedAlbums(size: 1))?.first
    }

    /// Loads the derived best-of playlists. Independent of `load()` and deliberately non-throwing: a server
    /// that fails or doesn't answer getStarred2 should cost the user the "Made For You" section, not the
    /// playlist list.
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
