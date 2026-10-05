import Foundation

/// AudioStreaming does not expose AVPlayer access logs or buffered ranges. Report only
/// observed transport values, without inventing those measurements or including source URLs.
nonisolated struct StreamingEngineDiagnosticSnapshot: Sendable, Equatable {
    let token: AudioEnginePlaybackToken
    let state: AudioEngineState
    let position: Double
    let duration: Double
    let renderedFrames: Int
    let intended: Bool
    let seeking: Bool
    let queued: Bool
    let overlapping: Bool
    let airPlay: Bool

    var description: String {
        "engine=AudioStreaming version=1.4.5 item=\(token.rawValue) state=\(state) position=\(position) duration=\(duration) rendered-frames=\(renderedFrames) intent-play=\(intended) seeking=\(seeking) queued=\(queued) overlap=\(overlapping) airplay=\(airPlay) pcm-hz=44100"
    }
}
