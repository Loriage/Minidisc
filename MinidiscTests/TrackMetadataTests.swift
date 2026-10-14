import Foundation
import Testing
import SwiftSonic
@testable import Minidisc

@Suite("Track metadata")
struct TrackMetadataTests {

    // MARK: - DisplayableSong

    @Test func displayableSong_fromSong_keepsCreditsAndAudioProperties() {
        let song = Song(
            id: "s1", title: "The Mountain", isDir: false, suffix: "flac", bitRate: 1213,
            artists: [ArtistID3(id: "gorillaz", name: "Gorillaz"), ArtistID3(id: "hopper", name: "Dennis Hopper")],
            bitDepth: 24, samplingRate: 48_000, channelCount: 2
        )
        let displayable = DisplayableSong(from: song)
        #expect(displayable.artists == [
            ArtistCredit(id: "gorillaz", name: "Gorillaz"),
            ArtistCredit(id: "hopper", name: "Dennis Hopper")
        ])
        #expect(displayable.bitRate == 1213)
        #expect(displayable.bitDepth == 24)
        #expect(displayable.samplingRate == 48_000)
        #expect(displayable.channelCount == 2)
        #expect(displayable.audioFormat == "FLAC")
    }

    @Test func displayableSong_decodesQueuesSavedBeforeCredits() throws {
        // A persisted queue entry written before artists / audio properties existed.
        let legacy = """
        [{"id":"s1","title":"Old","duration":200,"trackNumber":1,"isDownloaded":false}]
        """
        let songs = try JSONDecoder().decode([DisplayableSong].self, from: Data(legacy.utf8))
        #expect(songs.first?.artists == nil)
        #expect(songs.first?.bitRate == nil)
    }

    // MARK: - TrackArtistCredits

    @Test func credits_soleAlbumArtist_hidden() {
        let song = makeSong(artists: [ArtistCredit(id: "a", name: "Gorillaz")])
        #expect(TrackArtistCredits.credits(for: song, albumArtistID: "a", albumArtistName: "Gorillaz").isEmpty)
    }

    @Test func credits_withGuest_listsEveryArtist() {
        let credits = [ArtistCredit(id: "a", name: "Gorillaz"), ArtistCredit(id: "b", name: "Bootie Brown")]
        let song = makeSong(artists: credits)
        #expect(TrackArtistCredits.credits(for: song, albumArtistID: "a", albumArtistName: "Gorillaz") == credits)
    }

    @Test func credits_legacyArtistString_differentFromAlbumArtist_shown() {
        let song = makeSong(artist: "Various", artistId: nil)
        let credits = TrackArtistCredits.credits(for: song, albumArtistID: nil, albumArtistName: "Gorillaz")
        #expect(credits == [ArtistCredit(id: nil, name: "Various")])
    }

    @Test func credits_legacyArtistString_matchingByName_hidden() {
        let song = makeSong(artist: "gorillaz", artistId: nil)
        #expect(TrackArtistCredits.credits(for: song, albumArtistID: nil, albumArtistName: "Gorillaz").isEmpty)
    }

    // MARK: - ArtistAppearances

    @Test func appearances_keepsOnlyOtherArtistsAlbumsCreditingTheArtist() {
        let bill = ArtistID3(id: "bill", name: "Bill Evans")
        let stan = ArtistID3(id: "stan", name: "Stan Getz")
        let songs = [
            // Guest spot on Stan's album: counted.
            Song(id: "1", title: "A", isDir: false, album: "Getz & Evans", year: 1973, albumId: "getz",
                 artists: [stan, bill], albumArtists: [stan]),
            Song(id: "2", title: "B", isDir: false, album: "Getz & Evans", year: 1973, albumId: "getz",
                 artists: [stan, bill], albumArtists: [stan]),
            // Bill's own album: excluded.
            Song(id: "3", title: "C", isDir: false, album: "Alone", albumId: "alone",
                 artists: [bill], albumArtists: [bill]),
            // Name match without a credit: excluded.
            Song(id: "4", title: "D", isDir: false, album: "Tribute", albumId: "tribute",
                 artists: [stan], albumArtists: [stan])
        ]
        let albums = ArtistAppearances.albums(from: songs, artistID: "bill")
        #expect(albums.map(\.id) == ["getz"])
        #expect(albums.first?.songCount == 2)
        #expect(albums.first?.artist == "Stan Getz")
    }

    // MARK: - PlaybackSourceKind

    @Test func sourceKind_originalStream_isNotTranscoded() throws {
        let url = try #require(URL(string: "https://music.example.com/rest/stream?id=1&t=secret&estimateContentLength=true"))
        let kind = PlaybackSourceKind(.stream(url, customHeaders: [:]))
        #expect(kind == .stream(transcodedFormat: nil, maxBitRate: nil))
        #expect(!kind.isTranscoded)
    }

    @Test func sourceKind_mp3Stream_isTranscoded() throws {
        let url = try #require(URL(string: "https://music.example.com/rest/stream?id=1&format=mp3&maxBitRate=192"))
        let kind = PlaybackSourceKind(.stream(url, customHeaders: [:]))
        #expect(kind == .stream(transcodedFormat: "mp3", maxBitRate: 192))
        #expect(kind.isTranscoded)
    }

    // MARK: - PlaybackFormatDescription

    @Test func formatLine_download_showsSourceFormatAndBitRate() {
        var song = makeSong(audioFormat: "FLAC")
        song.bitRate = 1213
        let line = PlaybackFormatDescription(track: song, source: .downloaded, isCellular: false)
        #expect(line?.parts == ["Downloaded", "FLAC", "1213 kbps"])
        #expect(line?.systemImage == "arrow.down.circle")
    }

    @Test func formatLine_transcodedStream_showsRequestedFormat() {
        var song = makeSong()
        song.bitRate = 1213
        let line = PlaybackFormatDescription(
            track: song,
            source: .stream(transcodedFormat: "mp3", maxBitRate: 192),
            isCellular: true
        )
        #expect(line?.parts == ["Transcoding", "MP3", "192 kbps"])
        #expect(line?.systemImage == "cellularbars")
    }

    @Test func formatLine_radio_hidden() {
        #expect(PlaybackFormatDescription(track: makeSong(), source: .liveStream, isCellular: false) == nil)
    }

    private func makeSong(
        artist: String? = "Gorillaz",
        artistId: String? = "a",
        artists: [ArtistCredit]? = nil,
        audioFormat: String? = nil
    ) -> DisplayableSong {
        var song = DisplayableSong(
            id: "s", title: "T", artist: artist, albumId: "al", albumName: "Album", artistId: artistId,
            genre: nil, duration: 200, trackNumber: 1, isDownloaded: false, coverArtId: nil, audioFormat: audioFormat,
            replayGainTrackGain: nil, replayGainTrackPeak: nil, replayGainAlbumGain: nil,
            replayGainAlbumPeak: nil, replayGainBaseGain: nil, replayGainFallbackGain: nil
        )
        song.artists = artists
        return song
    }
}
