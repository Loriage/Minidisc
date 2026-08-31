import SwiftSonic
import Testing
@testable import Minidisc

@Suite("Album recommendations")
struct AlbumRecommendationTests {
    private func song(
        _ id: String,
        albumID: String?,
        album: String?,
        artistID: String? = nil,
        artist: String? = nil,
        coverArt: String? = nil
    ) -> Song {
        Song(
            id: id,
            title: "Track \(id)",
            album: album,
            artist: artist,
            coverArt: coverArt,
            albumId: albumID,
            artistId: artistID
        )
    }

    @Test("excludes the current album and its artist, then ranks repeated matches first")
    func excludesCurrentContextAndRanksMatches() {
        let matches = [
            song("current", albumID: "current-album", album: "Current", artistID: "current-artist"),
            song("same-artist", albumID: "same-artist-album", album: "More By", artistID: "current-artist"),
            song("b1", albumID: "album-b", album: "Album B", artistID: "artist-b", artist: "Artist B"),
            song("c1", albumID: "album-c", album: "Album C", artistID: "artist-c", artist: "Artist C"),
            song("b2", albumID: "album-b", album: "Album B", artistID: "artist-b", artist: "Artist B")
        ]

        let albums = LibraryService.albumRecommendations(
            from: matches,
            excludingAlbumID: "current-album",
            excludingArtistID: "current-artist",
            excludingArtistName: nil,
            limit: 10
        )

        #expect(albums.map(\.id) == ["album-b", "album-c"])
    }

    @Test("keeps at most two albums per recommended artist")
    func diversifiesArtists() {
        let matches = [
            song("a1", albumID: "album-a1", album: "A1", artistID: "artist-a", artist: "Artist A"),
            song("a2", albumID: "album-a2", album: "A2", artistID: "artist-a", artist: "Artist A"),
            song("a3", albumID: "album-a3", album: "A3", artistID: "artist-a", artist: "Artist A"),
            song("b1", albumID: "album-b1", album: "B1", artistID: "artist-b", artist: "Artist B")
        ]

        let albums = LibraryService.albumRecommendations(
            from: matches,
            excludingAlbumID: "current",
            excludingArtistID: nil,
            excludingArtistName: nil,
            limit: 10
        )

        #expect(albums.map(\.id) == ["album-a1", "album-a2", "album-b1"])
    }

    @Test("ignores incomplete matches and preserves card metadata")
    func ignoresIncompleteMatches() {
        let matches = [
            song("missing-id", albumID: nil, album: "Missing"),
            song("missing-name", albumID: "missing-name", album: nil),
            song(
                "valid",
                albumID: "recommended",
                album: "Recommended",
                artistID: "artist",
                artist: "The Artist",
                coverArt: "cover"
            )
        ]

        let album = LibraryService.albumRecommendations(
            from: matches,
            excludingAlbumID: "current",
            excludingArtistID: nil,
            excludingArtistName: nil,
            limit: 1
        ).first

        #expect(album?.id == "recommended")
        #expect(album?.name == "Recommended")
        #expect(album?.artist == "The Artist")
        #expect(album?.coverArt == "cover")
    }
}
