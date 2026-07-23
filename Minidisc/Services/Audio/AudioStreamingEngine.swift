// Minidisc — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import AudioStreaming
import Foundation
import OSLog

/// The default engine: wraps AudioStreaming's `AudioPlayer` behind the neutral `AudioEngine` contract.
/// Behavior is unchanged from driving `AudioPlayer` directly — this is a thin, 1:1 pass-through.
///
/// `player` is exposed so `ReplayGainService` can attach its EQ frame filter, which is specific to
/// AudioStreaming's audio graph. The AVAudioEngine backend applies ReplayGain with its own gain node.
nonisolated final class AudioStreamingEngine: AudioEngine, @unchecked Sendable {
    /// AudioPlayer has its own internal queue; access is thread-safe.
    let player: AudioPlayer
    private let bridge = Bridge()

    weak var delegate: AudioEngineDelegate? {
        get { bridge.delegate }
        set { bridge.delegate = newValue }
    }

    init() {
        let config = AudioPlayerConfiguration(
            flushQueueOnSeek: true,
            bufferSizeInSeconds: 20,
            secondsRequiredToStartPlaying: 1,
            gracePeriodAfterSeekInSeconds: 0.5,
            secondsRequiredToStartPlayingAfterBufferUnderrun: 1,
            enableLogs: false
        )
        player = AudioPlayer(configuration: config)
        player.delegate = bridge
    }

    func play(url: URL, headers: [String: String]) { player.play(url: url, headers: headers) }
    func pause() { player.pause() }
    func resume() { player.resume() }
    func stop() { player.stop() }
    func seek(to seconds: Double) { player.seek(to: seconds) }

    var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }
    var progress: Double { player.progress }
    var duration: Double { player.duration }
    var isSeekable: Bool { player.isSeekable }
    var isReady: Bool { player.state == .ready }

    /// Translates `AudioPlayerDelegate` callbacks into the neutral `AudioEngineDelegate`.
    private nonisolated final class Bridge: AudioPlayerDelegate, @unchecked Sendable {
        weak var delegate: AudioEngineDelegate?

        func audioPlayerDidStartPlaying(player: AudioPlayer, with entryId: AudioEntryId) {}
        func audioPlayerDidFinishBuffering(player: AudioPlayer, with entryId: AudioEntryId) {}

        func audioPlayerStateChanged(player: AudioPlayer, with newState: AudioPlayerState, previous: AudioPlayerState) {
            // [DIAG] Underrun while cover fetches are in flight confirms bandwidth starvation.
            if newState == .bufferring && previous == .playing {
                Logger.player.warning("[NET-AUDIO] buffer underrun — state: playing → bufferring")
            }
            delegate?.audioEngineDidChangeState(Self.map(newState))
        }

        func audioPlayerDidFinishPlaying(player: AudioPlayer, entryId: AudioEntryId, stopReason: AudioPlayerStopReason, progress: Double, duration: Double) {
            // Only natural completions (eof) trigger end-of-track handling.
            guard stopReason == .eof else { return }
            delegate?.audioEngineDidReachEndOfTrack()
        }

        func audioPlayerUnexpectedError(player: AudioPlayer, error: AudioPlayerError) {
            delegate?.audioEngineDidError(error.localizedDescription)
        }

        func audioPlayerDidCancel(player: AudioPlayer, queuedItems: [AudioEntryId]) {}
        func audioPlayerDidReadMetadata(player: AudioPlayer, metadata: [String: String]) {}

        static func map(_ state: AudioPlayerState) -> AudioEngineState {
            switch state {
            case .ready:              return .ready
            case .bufferring:         return .buffering
            case .playing, .running:  return .playing
            case .paused:             return .paused
            case .stopped:            return .stopped
            case .error:              return .error
            case .disposed:           return .other
            }
        }
    }
}
