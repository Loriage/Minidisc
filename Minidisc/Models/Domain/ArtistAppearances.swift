import Foundation
import SwiftSonic

/// Albums by other artists (or filed under another artist) that credit an artist on at least one track,
/// with the credited tracks themselves. This is what credit-only artists such as an ensemble whose albums
/// are filed under its leader ("Bill Evans Trio" under "Bill Evans") are made of.
nonisolated struct ArtistAppearanceResult: Sendable {
    let albums: [AlbumID3]
    /// The credited tracks, newest album first and in track order within an album.
    let songs: [Song]

    static let empty = ArtistAppearanceResult(albums: [], songs: [])
}

nonisolated enum ArtistAppearances {
    /// A track credits the artist when its OpenSubsonic `artists` list names them, or, on servers without
    /// that list, when the artist is the primary track artist. Plain artist strings are never matched by
    /// name. Albums filed under the artist (`albumArtists`) or listed in `excludingAlbumIDs` are dropped.
    /// `albumHeaders` supplies full album records (true song count, artist, year) when known.
    static func result(
        from songs: [Song],
        artistID: String,
        excludingAlbumIDs: Set<String> = [],
        albumHeaders: [String: AlbumID3] = [:]
    ) -> ArtistAppearanceResult {
        var order: [String] = []
        var groups: [String: [Song]] = [:]
        for song in songs {
            guard let albumID = song.albumId,
                  !excludingAlbumIDs.contains(albumID),
                  credits(song, artistID: artistID),
                  song.albumArtists?.contains(where: { $0.id == artistID }) != true else { continue }
            if groups[albumID] == nil { order.append(albumID) }
            groups[albumID, default: []].append(song)
        }

        let albums: [AlbumID3] = order.compactMap { albumID in
            if let header = albumHeaders[albumID] {
                // The header knows the filing artist even when tracks lack `albumArtists`.
                return header.artistId == artistID ? nil : header
            }
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

        let orderedSongs = albums.flatMap { album in
            (groups[album.id] ?? []).sorted {
                (($0.discNumber ?? 1), ($0.track ?? 0)) < (($1.discNumber ?? 1), ($1.track ?? 0))
            }
        }
        return ArtistAppearanceResult(albums: albums, songs: orderedSongs)
    }

    static func albums(
        from songs: [Song],
        artistID: String,
        excludingAlbumIDs: Set<String> = []
    ) -> [AlbumID3] {
        result(from: songs, artistID: artistID, excludingAlbumIDs: excludingAlbumIDs).albums
    }

    private static func credits(_ song: Song, artistID: String) -> Bool {
        if let artists = song.artists, !artists.isEmpty {
            return artists.contains { $0.id == artistID }
        }
        return song.artistId == artistID
    }
}
