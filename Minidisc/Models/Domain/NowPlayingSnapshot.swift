import Foundation

nonisolated struct NowPlayingSnapshot: Sendable {
    let title: String
    let artist: String?
    let album: String?
    let duration: TimeInterval
    let position: TimeInterval
    let playbackRate: Float
    let artworkURL: URL?
    let artworkHeaders: [String: String]
    let coverArtId: String?
    /// True when the current playback is a live stream (radio). When true, duration and
    /// position are not meaningful — NowPlayingService omits them from the info dict so
    /// Control Center hides the scrubber automatically.
    let isLiveStream: Bool
    let radioStationName: String?
    /// Id of the playing song, so the remote like command knows what to star. `nil` for radio,
    /// which has nothing to favourite.
    let songId: String?
}
