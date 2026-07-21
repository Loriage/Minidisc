// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

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
    private(set) var genreShelves: [GenreShelf] = []
    var isLoading = false
    var error: UserFacingError?

    var isEmpty: Bool { topPicks.isEmpty && recentlyPlayed.isEmpty && genreShelves.isEmpty }

    private let libraryService: any LibraryServiceProtocol

    private static let maxTopPicks = 8
    private static let maxGenreShelves = 5
    private static let shelfSize = 20

    init(libraryService: any LibraryServiceProtocol) {
        self.libraryService = libraryService
    }

    func load() async {
        isLoading = true
        error = nil
        do {
            async let playlistsTask = libraryService.playlists()
            async let playedTask = libraryService.recentlyPlayedAlbums(size: Self.shelfSize)
            async let genresTask = libraryService.genres()
            let (playlists, played, genres) = try await (playlistsTask, playedTask, genresTask)

            topPicks = playlists
                .sorted { ($0.changed ?? $0.created ?? .distantPast) > ($1.changed ?? $1.created ?? .distantPast) }
                .prefix(Self.maxTopPicks)
                .map { $0 }
            recentlyPlayed = played

            // Sequential on purpose: one getAlbumList2 per genre is light, and order stays stable.
            var shelves: [GenreShelf] = []
            for genre in genres.filter({ $0.albumCount > 0 }).sorted(by: { $0.albumCount > $1.albumCount }).prefix(Self.maxGenreShelves) {
                if let albums = try? await libraryService.albumsByGenre(genre.value, size: Self.shelfSize), !albums.isEmpty {
                    shelves.append(GenreShelf(name: genre.value, albums: albums))
                }
            }
            genreShelves = shelves
        } catch {
            self.error = UserFacingError.from(error)
        }
        isLoading = false
    }
}
