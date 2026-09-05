import Foundation
import SwiftSonic

/// A library artist is the actual Instant Mix seed; names alone never identify a station.
struct ArtistStation: Identifiable, Sendable {
    let artist: FeaturedArtist
    let starter: DisplayableSong?
    var id: String { artist.id }

    static func suggestions(favorites: HomeFavorites, recent: [AlbumID3], frequent: [AlbumID3], limit: Int = 10) -> [ArtistStation] {
        let songs = favorites.songs.map { DisplayableSong(from: $0) }
        var artists = favorites.artists.map { FeaturedArtist(id: $0.id, name: $0.name, coverArtId: $0.coverArt) }
        artists += songs.compactMap { song in
            guard let id = song.artistId, let name = song.artist else { return nil }
            return FeaturedArtist(id: id, name: name, coverArtId: song.coverArtId)
        }
        artists += (recent + frequent + favorites.albums).compactMap { album in
            guard let id = album.artistId, let name = album.artist else { return nil }
            return FeaturedArtist(id: id, name: name, coverArtId: album.coverArt)
        }
        var seen = Set<String>()
        return artists.filter {
            !$0.id.isEmpty && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seen.insert($0.id).inserted
        }.prefix(max(0, limit)).map { artist in
            ArtistStation(artist: artist, starter: songs.first { $0.artistId == artist.id })
        }
    }
}
