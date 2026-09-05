import SwiftSonic

extension DisplayableSong {
    func asSong() -> Song {
        Song(
            id: id,
            title: title,
            parent: nil,
            isDir: false,
            album: albumName,
            artist: artist,
            track: trackNumber,
            year: nil,
            genre: genre,
            coverArt: coverArtId,
            size: nil,
            contentType: nil,
            suffix: audioFormat?.lowercased(),
            transcodedContentType: nil,
            transcodedSuffix: nil,
            duration: duration > 0 ? Int(duration) : nil,
            bitRate: nil,
            path: nil,
            isVideo: false,
            userRating: nil,
            averageRating: nil,
            playCount: nil,
            discNumber: nil,
            created: nil,
            starred: nil,
            albumId: albumId,
            artistId: artistId,
            type: nil
        )
    }
}
