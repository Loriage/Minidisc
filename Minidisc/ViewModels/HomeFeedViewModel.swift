import Foundation
import Observation
import SwiftSonic

/// Feed for the personalized Home tab: playlists as "Top Picks for You"
/// (freshest first), recently played albums, and one shelf per top genre.
@Observable
@MainActor
final class HomeFeedViewModel {
    nonisolated struct GenreShelf: Identifiable, Sendable {
        let name: String
        let albums: [AlbumID3]
        var id: String { name }
    }

    private(set) var topPicks: [Playlist] = []
    private(set) var recentlyPlayed: [AlbumID3] = []
    private(set) var recentlyAdded: [AlbumID3] = []
    private(set) var genreShelves: [GenreShelf] = []
    var isLoading = false
    var error: UserFacingError?

    var isEmpty: Bool { topPicks.isEmpty && recentlyPlayed.isEmpty && recentlyAdded.isEmpty && genreShelves.isEmpty }

    private let libraryService: any PlaylistBrowsing
        & RecentlyAddedAlbumBrowsing
        & ListeningHistoryBrowsing
        & GenreBrowsing

    private static let maxTopPicks = 8
    private static let maxGenreShelves = 5
    private static let shelfSize = 20

    init(
        libraryService: any PlaylistBrowsing
            & RecentlyAddedAlbumBrowsing
            & ListeningHistoryBrowsing
            & GenreBrowsing
    ) {
        self.libraryService = libraryService
    }

    func load() async {
        isLoading = true
        error = nil
        do {
            async let playlistsTask = libraryService.playlists()
            async let playedTask = libraryService.recentlyPlayedAlbums(size: Self.shelfSize)
            async let addedTask = libraryService.recentlyAddedAlbums(size: Self.shelfSize)
            async let genresTask = libraryService.genres()
            let (playlists, played, added, genres) = try await (playlistsTask, playedTask, addedTask, genresTask)

            let picks = playlists
                .sorted { ($0.changed ?? $0.created ?? .distantPast) > ($1.changed ?? $1.created ?? .distantPast) }
                .prefix(Self.maxTopPicks)
                .map { $0 }

            // Sequential on purpose: one getAlbumList2 per genre is light, and order stays stable.
            var shelves: [GenreShelf] = []
            for genre in genres.filter({ $0.albumCount > 0 }).sorted(by: { $0.albumCount > $1.albumCount }).prefix(Self.maxGenreShelves) {
                if let albums = try? await libraryService.albumsByGenre(genre.value, size: Self.shelfSize), !albums.isEmpty {
                    shelves.append(GenreShelf(name: genre.value, albums: albums))
                }
            }

            // Apply the whole feed at once. A staged assignment (top shelves first, genres after the
            // per-genre fetches) changes the scroll content height twice mid-refresh, which can strand
            // the pull-to-refresh inset and leave a blank gap at the top until the user scrolls.
            topPicks = picks
            recentlyPlayed = played
            recentlyAdded = added
            genreShelves = shelves
        } catch {
            self.error = UserFacingError.from(error)
        }
        isLoading = false
    }
}
