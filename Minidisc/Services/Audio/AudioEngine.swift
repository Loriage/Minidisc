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

/// Stable identity of one physical item loaded by an `AudioEngine`.
///
/// A track id is not sufficient here: the same song can legitimately appear twice in a queue, and
/// AVFoundation may deliver an already-queued callback after a newer item has replaced it. The token
/// lets the orchestration layer reject those stale state/error/end events without guessing from song
/// metadata.
nonisolated struct AudioEnginePlaybackToken: Hashable, Sendable {
    let rawValue: UInt64

    init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

/// Safe diagnostics copied before AVPlayer releases a failed item. Never retain userInfo,
/// localized descriptions, error-log URLs, headers, or server-provided comments.
nonisolated struct AudioEngineFailure: Sendable, Equatable {
    struct Code: Sendable, Equatable {
        enum Domain: String, Sendable {
            case avFoundation, url, coreMedia, osStatus, other

            init(_ domain: String) {
                self = switch domain {
                case "AVFoundationErrorDomain": .avFoundation
                case NSURLErrorDomain: .url
                case "CoreMediaErrorDomain": .coreMedia
                case NSOSStatusErrorDomain: .osStatus
                default: .other
                }
            }
        }

        let domain: Domain
        let value: Int

        init(domain: String, value: Int) {
            self.domain = Domain(domain)
            self.value = value
        }
    }

    let codes: [Code]

    init(error: (any Error)?, logCode: Code? = nil) {
        var codes: [Code] = []
        var current = error as NSError?
        // A malformed NSError can even contain a cycle in its underlying-error chain.
        for _ in 0..<5 {
            guard let error = current else { break }
            codes.append(Code(domain: error.domain, value: error.code))
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        if let logCode, !codes.contains(logCode) { codes.append(logCode) }
        self.codes = codes
    }

    var diagnosticDescription: String {
        codes.isEmpty ? "unknown" : codes.map { "\($0.domain.rawValue):\($0.value)" }.joined(separator: ",")
    }
}

/// A standby item that the engine has already promoted to the active output.
///
/// The orchestration layer uses this snapshot to adopt the exact physical playback without
/// resolving the media URL again at the network-sensitive transition boundary.
nonisolated struct AudioEnginePromotedPlayback: Sendable, Equatable {
    let playbackToken: AudioEnginePlaybackToken
    let trackID: String
    let sourceURL: URL
    let sourceHeaders: [String: String]
    /// Wall-clock instant at which the incoming deck became audible.
    let startedAt: Date
    /// Current position in the promoted item, including any lead-in seek.
    let position: TimeInterval
    /// Audio from the promoted item that has already been heard during an overlap.
    let audibleDuration: TimeInterval
}

/// Everything known at a natural track boundary, captured before deck roles change.
nonisolated struct AudioEngineTrackEnd: Sendable, Equatable {
    let endedPlaybackToken: AudioEnginePlaybackToken
    let endedPosition: TimeInterval
    let promotedPlayback: AudioEnginePromotedPlayback?
}

/// Events an `AudioEngine` reports back. Called on the engine's callback thread; a consumer that is an
/// actor hops to its executor itself (as `PlayerService` does today).
nonisolated protocol AudioEngineDelegate: AnyObject, Sendable {
    func audioEngineDidChangeState(_ state: AudioEngineState, playbackToken: AudioEnginePlaybackToken)
    /// The current track finished on its own (end of file), not by a user stop/skip.
    func audioEngineDidReachEndOfTrack(_ transition: AudioEngineTrackEnd)
    func audioEngineDidError(_ failure: AudioEngineFailure, playbackToken: AudioEnginePlaybackToken)
}

/// The low-level audio player `PlayerService` drives. All the queue, now-playing, crossfade, and
/// session-restore orchestration stays in `PlayerService`; the engine only decodes and renders.
///
/// The engine has its own internal locking and is safe to call from any isolation, so requirements
/// are synchronous. `volume` is the user-facing volume (ReplayGain runs on a separate path).
nonisolated protocol AudioEngine: AnyObject, Sendable {
    var delegate: AudioEngineDelegate? { get set }

    /// Starts or adopts an item and returns the identity attached to all callbacks for that load.
    @discardableResult
    func play(trackID: String, url: URL, headers: [String: String]) -> AudioEnginePlaybackToken
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
