import Foundation
import Testing
@testable import Minidisc

@Suite("Track sharing")
struct TrackSharingServiceTests {
    @Test("Uses the server's public link when sharing is available")
    func usesPublicLink() async throws {
        let expected = try #require(URL(string: "https://music.example/share/abc"))
        let service = TrackSharingService { _ in expected }

        let result = await service.prepareShare(for: makeSong(), serverIsReachable: true)

        #expect(result == .publicLink(expected))
    }

    @Test("Uses local metadata while offline")
    func offlineFallback() async {
        let service = TrackSharingService { _ in
            URL(string: "https://music.example/share/unused")
        }

        let result = await service.prepareShare(for: makeSong(), serverIsReachable: false)

        #expect(result == .metadata("♫ Track\nArtist · Album"))
    }

    @Test("Uses local metadata when public link creation fails")
    func failedServerFallback() async {
        let service = TrackSharingService { _ in throw StubError.unavailable }

        let result = await service.prepareShare(for: makeSong(), serverIsReachable: true)

        #expect(result == .metadata("♫ Track\nArtist · Album"))
    }

    @Test("Omits blank metadata and trims shared text")
    func cleansMetadata() {
        let song = makeSong(title: "  Track  ", artist: "  ", albumName: "  Album  ")

        #expect(TrackSharingService.metadataText(for: song) == "♫ Track\nAlbum")
    }

    @Test("Cancellation does not open the share sheet")
    func cancellation() async {
        let service = TrackSharingService { _ in throw CancellationError() }

        let result = await service.prepareShare(for: makeSong(), serverIsReachable: true)

        #expect(result == nil)
    }

    private enum StubError: Error {
        case unavailable
    }

    private func makeSong(
        title: String = "Track",
        artist: String? = "Artist",
        albumName: String? = "Album"
    ) -> DisplayableSong {
        DisplayableSong(
            id: "track-id",
            title: title,
            artist: artist,
            albumId: "album-id",
            albumName: albumName,
            artistId: "artist-id",
            genre: nil,
            duration: 180,
            trackNumber: 1,
            isDownloaded: false,
            coverArtId: nil,
            audioFormat: "FLAC",
            replayGainTrackGain: nil,
            replayGainTrackPeak: nil,
            replayGainAlbumGain: nil,
            replayGainAlbumPeak: nil,
            replayGainBaseGain: nil,
            replayGainFallbackGain: nil
        )
    }
}
