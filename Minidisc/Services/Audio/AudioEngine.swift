import Foundation

/// The low-level playback state an `AudioEngine` reports, independent of any concrete backend so
/// another engine could drive the same `PlayerService` orchestration.
nonisolated enum AudioEngineState: Equatable, Sendable {
    case buffering
    case playing
    case paused
    case stopped
    case error
}

/// Events an `AudioEngine` reports back. Called on the engine's callback thread; a consumer that is an
/// actor hops to its executor itself (as `PlayerService` does today).
nonisolated protocol AudioEngineDelegate: AnyObject, Sendable {
    func audioEngineDidChangeState(_ state: AudioEngineState)
    /// The current track finished on its own (end of file), not by a user stop/skip.
    func audioEngineDidReachEndOfTrack()
    func audioEngineDidError(_ message: String)
}

/// The low-level audio player `PlayerService` drives. All the queue, now-playing, crossfade, and
/// session-restore orchestration stays in `PlayerService`; the engine only decodes and renders.
///
/// The engine has its own internal locking and is safe to call from any isolation, so requirements
/// are synchronous. `volume` is the user-facing volume (ReplayGain runs on a separate path).
nonisolated protocol AudioEngine: AnyObject, Sendable {
    var delegate: AudioEngineDelegate? { get set }

    func play(trackID: String, url: URL, headers: [String: String])
    func pause()
    func resume()
    func stop()
    /// Repositions the active deck and returns only after AVPlayer has completed (or rejected) the seek.
    /// `false` also covers a deck transition that made the request stale while it was in flight.
    func seek(to seconds: Double) async -> Bool

    var volume: Float { get set }
    var progress: Double { get }
    var duration: Double { get }
    var isSeekable: Bool { get }
    /// True when idle and ready to start a source (the cold-restore path checks this).
    var isReady: Bool { get }

    /// Applies a ReplayGain loudness adjustment in dB for the current track (0 = no change).
    func applyReplayGain(dB: Float)

    /// Hints that `url` will very likely be the next `play` target, so the engine can pre-buffer it
    /// for a seamless hand-off. `crossfadeDuration` == 0 asks for a gapless butt-splice; > 0 asks the
    /// engine to blend the two tracks over that window. A later `play` with the same stable track ID
    /// adopts the pre-buffered source; any other ID discards it.
    /// `leadInTrim` skips that many seconds of silence at the start of the preloaded track, so a
    /// gapless pair butts together instead of playing the encoder's padding.
    func preloadNext(
        trackID: String,
        url: URL,
        headers: [String: String],
        crossfadeDuration: Double,
        leadInTrim: Double,
        replayGainDB: Float
    )

    /// Drops a pending standby deck without touching the active track.
    func cancelPreload()

    /// Ends the CURRENT track `seconds` early, cutting its trailing silence. 0 restores the full
    /// length. Only meaningful ahead of a gapless hand-off; a crossfade wants the real tail.
    func setTrackEndTrim(_ seconds: Double)

    /// The authoritative length of the current track from library metadata, for engines whose own
    /// duration estimate drifts (transcoded/VBR streams) and would mistime transitions.
    func setTrackDuration(_ seconds: Double)
}
