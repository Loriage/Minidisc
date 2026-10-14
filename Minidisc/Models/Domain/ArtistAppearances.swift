import Foundation
import SwiftSonic

/// Builds an artist's "Appears On" shelf: albums by other artists that credit the artist on at least one track.
nonisolated enum ArtistAppearances {
    /// Only OpenSubsonic `artists` / `albumArtists` credits are trusted; plain artist strings would match
    /// unrelated names. Albums in `excludingAlbumIDs` (the artist's own discography) are dropped.
    static func albums(
        from songs: [Song],
        artistID: String,
        excludingAlbumIDs: Set<String> = []
    ) -> [AlbumID3] {
        var order: [String] = []
        var groups: [String: [Song]] = [:]
        for song in songs {
            guard let albumID = song.albumId,
                  !excludingAlbumIDs.contains(albumID),
                  song.artists?.contains(where: { $0.id == artistID }) == true,
                  song.albumArtists?.contains(where: { $0.id == artistID }) != true else { continue }
            if groups[albumID] == nil { order.append(albumID) }
            groups[albumID, default: []].append(song)
        }

        return order.compactMap { albumID in
            guard let tracks = groups[albumID], let first = tracks.first else { return nil }
            let albumArtist = first.displayAlbumArtist
                ?? first.albumArtists?.map(\.name).joined(separator: ", ")
            return AlbumID3(
                id: albumID,
                name: first.album ?? "",
                songCount: tracks.count,
                duration: tracks.reduce(0) { $0 + ($1.duration ?? 0) },
                artist: albumArtist,
                artistId: first.albumArtists?.first?.id,
                coverArt: first.coverArt,
                year: first.year
            )
        }
        .sorted { ($0.year ?? 0) > ($1.year ?? 0) }
    }
}
