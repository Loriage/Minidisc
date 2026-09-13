import Foundation
import SwiftSonic

/// Virtual playlist derived from starred tracks; never creates a server playlist.
nonisolated struct ArtistBestOf: Identifiable, Hashable, Sendable {
    static let minimumSongs = 5

    let artistId: String
    let artistName: String
    let coverArtId: String?
    let songs: [DisplayableSong]

    var id: String { artistId }
}

extension ArtistBestOf {
    /// Groups by artist ID. Name-only grouping would merge distinct artists with the same name.
    static func all(in starred: [Song]) -> [ArtistBestOf] {
        Dictionary(grouping: starred.filter { $0.artistId != nil }, by: { $0.artistId! })
            .compactMap { artistId, songs -> ArtistBestOf? in
                guard songs.count >= minimumSongs else { return nil }
                let ordered = songs.mostRecentlyStarredFirst
                return ArtistBestOf(
                    artistId: artistId,
                    artistName: ordered.first?.artist ?? "",
                    coverArtId: ordered.first?.coverArt,
                    songs: ordered.map { DisplayableSong(from: $0) }
                )
            }
            .sorted {
                $0.songs.count == $1.songs.count
                    ? $0.artistName.localizedCaseInsensitiveCompare($1.artistName) == .orderedAscending
                    : $0.songs.count > $1.songs.count
            }
    }

    static func songs(of artistId: String, named artistName: String?, in starred: [Song]) -> [DisplayableSong] {
        starred
            .filter { matches($0, artistId: artistId, artistName: artistName) }
            .mostRecentlyStarredFirst
            .map { DisplayableSong(from: $0) }
    }

    /// Matches every id the server might carry (track artist, OpenSubsonic contributors, album artists),
    /// falling back to a name compare only when the track has no artist id at all — some servers drop it
    /// from the starred payload.
    static func matches(_ song: Song, artistId: String, artistName: String?) -> Bool {
        if song.artistId == artistId { return true }
        if song.artists?.contains(where: { $0.id == artistId }) == true { return true }
        if song.albumArtists?.contains(where: { $0.id == artistId }) == true { return true }
        guard song.artistId == nil, let artistName, let songArtist = song.artist else { return false }
        return songArtist.localizedCaseInsensitiveCompare(artistName) == .orderedSame
    }

    /// Trust fetched stars until the local cache has completed its first sync.
    static func filteredByLocalStars(_ songs: [DisplayableSong], starredSongIds: Set<String>) -> [DisplayableSong] {
        guard !starredSongIds.isEmpty else { return songs }
        return songs.filter { starredSongIds.contains($0.id) }
    }
}

private extension Array where Element == Song {
    var mostRecentlyStarredFirst: [Song] {
        sorted { ($0.starred ?? .distantPast) > ($1.starred ?? .distantPast) }
    }
}
