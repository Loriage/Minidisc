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
        #expect(albums.first?.songCount == 0, "Without a header the album size is unknown, not the credit count.")
        #expect(albums.first?.artist == "Stan Getz")
    }

    @Test func appearances_primaryCreditWithoutArtistsList_counts_andHeaderFilingExcludes() {
        // Legacy servers: no `artists` list, the primary track artist is the credit.
        let ensemble = Song(id: "1", title: "A", isDir: false, album: "Live", albumId: "live", artistId: "trio")
        let own = Song(id: "2", title: "B", isDir: false, album: "Own", albumId: "own", artistId: "trio")
        let headers = [
            "live": AlbumID3(id: "live", name: "Live", songCount: 9, duration: 2700, artist: "Bill Evans", artistId: "evans", year: 1961),
            "own": AlbumID3(id: "own", name: "Own", songCount: 5, duration: 900, artist: "Trio", artistId: "trio")
        ]
        let result = ArtistAppearances.result(from: [ensemble, own], artistID: "trio", albumHeaders: headers)
        #expect(result.albums.map(\.id) == ["live"])
        #expect(result.albums.first?.songCount == 9, "Index headers carry the real album size.")
        #expect(result.songs.map(\.id) == ["1"])
    }

    @Test func isFiled_usesAlbumArtistNotListing() {
        let filedUnderLeader = AlbumID3(id: "p", name: "Portrait in Jazz", songCount: 10, duration: 2800,
                                        artist: "Bill Evans", artistId: "evans")
        #expect(!ArtistAppearances.isFiled(filedUnderLeader, under: "trio", named: "Bill Evans Trio"))
        #expect(ArtistAppearances.isFiled(filedUnderLeader, under: "evans", named: "Bill Evans"))
        let coBilled = AlbumID3(id: "c", name: "Duo", songCount: 8, duration: 2000,
                                artists: [ArtistID3(id: "chet", name: "Chet Baker"), ArtistID3(id: "evans", name: "Bill Evans")])
        #expect(ArtistAppearances.isFiled(coBilled, under: "evans", named: "Bill Evans"))
        let unknown = AlbumID3(id: "u", name: "Unknown", songCount: 1, duration: 60)
        #expect(ArtistAppearances.isFiled(unknown, under: "evans", named: "Bill Evans"), "No filing data keeps the album.")
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

@Suite("Appears On sources")
struct AppearsOnSourceTests {
    private struct Failure: Error {}

    private func song(_ id: String) -> Song { Song(id: id, title: id, isDir: false) }

    @Test func online_asksServerEvenWhenIndexHasAnAnswer() async throws {
        // The reported bug: a stale index that knows one credited album must not hide the others.
        let songs = try await LibraryService.creditedSongs(isOnline: true, indexed: [song("known")]) {
            [song("known"), song("unscanned")]
        }
        #expect(songs.map(\.id) == ["known", "unscanned"])
    }

    @Test func online_keepsIndexOnlyCredits() async throws {
        let songs = try await LibraryService.creditedSongs(isOnline: true, indexed: [song("local")]) {
            [song("server")]
        }
        #expect(Set(songs.map(\.id)) == ["server", "local"])
    }

    @Test func offline_usesIndexWithoutCallingServer() async throws {
        var called = false
        let songs = try await LibraryService.creditedSongs(isOnline: false, indexed: [song("local")]) {
            called = true
            return []
        }
        #expect(!called)
        #expect(songs.map(\.id) == ["local"])
    }

    @Test func serverFailure_fallsBackToIndex() async throws {
        let songs = try await LibraryService.creditedSongs(isOnline: true, indexed: [song("local")]) {
            throw Failure()
        }
        #expect(songs.map(\.id) == ["local"])
    }

    @Test func serverFailure_withoutIndex_throws() async {
        await #expect(throws: Failure.self) {
            try await LibraryService.creditedSongs(isOnline: true, indexed: nil) { throw Failure() }
        }
    }
}
