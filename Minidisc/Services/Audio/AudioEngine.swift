// Minidisc — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

/// The low-level playback state an `AudioEngine` reports, independent of any concrete backend so
/// another engine could drive the same `PlayerService` orchestration.
nonisolated enum AudioEngineState: Equatable, Sendable {
    /// Idle and ready to start a source.
    case ready
    case buffering
    case playing
    case paused
    case stopped
    case error
    /// Anything the orchestration does not act on (running, disposed, unknown).
    case other
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

    func play(url: URL, headers: [String: String])
    func pause()
    func resume()
    func stop()
    func seek(to seconds: Double)

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
    /// engine to blend the two tracks over that window. A later `play` with the same URL adopts the
    /// pre-buffered source; any other URL discards it.
    func preloadNext(url: URL, headers: [String: String], crossfadeDuration: Double)

    /// The authoritative length of the current track from library metadata, for engines whose own
    /// duration estimate drifts (transcoded/VBR streams) and would mistime transitions.
    func setTrackDuration(_ seconds: Double)
}
