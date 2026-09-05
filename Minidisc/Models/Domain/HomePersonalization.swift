import Foundation
import SwiftSonic

nonisolated struct HomeFavorites: Codable, Sendable {
    var songs: [Song] = []
    var albums: [AlbumID3] = []
    var artists: [ArtistID3] = []
}

enum HomePersonalization {
    static func unique(_ albums: [AlbumID3], excluding ids: Set<String> = []) -> [AlbumID3] {
        var seen = ids
        return albums.filter { seen.insert($0.id).inserted }
    }

    /// A familiar album outside the latest listening history makes a useful rediscovery.
    /// Its source remains the listener's favorites and most-played albums.
    static func rediscovery(favorites: [AlbumID3], frequent: [AlbumID3], recent: [AlbumID3]) -> [AlbumID3] {
        unique(favorites + frequent, excluding: Set(recent.map(\.id))).prefix(12).map { $0 }
    }

    static func relevantAdditions(_ additions: [AlbumID3], favorites: HomeFavorites, frequent: [AlbumID3]) -> [AlbumID3] {
        let ids = Set(favorites.artists.map(\.id) + favorites.albums.compactMap(\.artistId)
                      + favorites.songs.compactMap(\.artistId) + frequent.prefix(8).compactMap(\.artistId))
        // Names are a fallback only for servers that omit artist IDs.
        let names = Set((favorites.artists.map(\.name) + favorites.albums.compactMap(\.artist)
                         + favorites.songs.compactMap(\.artist) + frequent.prefix(8).compactMap(\.artist))
            .map(LibrarySearchRanking.normalized).filter { !$0.isEmpty })
        return unique(additions.filter { album in
            if let id = album.artistId { return ids.contains(id) }
            return album.artist.map { names.contains(LibrarySearchRanking.normalized($0)) } ?? false
        })
    }
}
