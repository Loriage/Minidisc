import Testing
@testable import Minidisc

@Suite("Playlist addition")
@MainActor
struct PlaylistAdditionTests {
    @Test func presentationUsesOneSelectedSong() {
        let first = makeSong(id: "first")
        let second = makeSong(id: "second")
        let addition = PlaylistAddition()

        addition.present(first)
        #expect(addition.selectedSong == first)

        addition.present(second)
        #expect(addition.selectedSong == second)

        addition.dismiss()
        #expect(addition.selectedSong == nil)
    }

    private func makeSong(id: String) -> DisplayableSong {
        DisplayableSong(
            id: id,
            title: "Track",
            artist: "Artist",
            albumId: nil,
            albumName: nil,
            artistId: nil,
            genre: nil,
            duration: 120,
            trackNumber: nil,
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
