import AVFoundation
@preconcurrency import AudioStreaming
import Foundation

nonisolated enum StreamingDriverEvent: Sendable {
    case started(UUID)
    case finished(UUID, natural: Bool, position: Double)
    case state(AudioEngineState)
    case failed(AudioEngineFailure)
}

/// Narrow boundary for testing transport races without replacing the orchestration service.
nonisolated protocol StreamingAudioDriver: AnyObject, Sendable {
    var onEvent: (@Sendable (StreamingDriverEvent) -> Void)? { get set }
    var state: AudioEngineState { get }
    var position: Double { get }
    var duration: Double { get }
    var renderedFrames: Int { get }
    var isSeekable: Bool { get }
    var volume: Float { get set }
    var muted: Bool { get set }
    func applyGain(dB: Float)
    func play(url: URL, headers: [String: String])
    func queue(url: URL, headers: [String: String])
    func pause()
    func resume()
    func stop()
    func seek(to seconds: Double)
}

/// AudioStreaming owns its decoding queues. This wrapper serializes only delegate bookkeeping;
/// the engine serializes its control calls. Raw URL-based entry identifiers never leave it.
nonisolated final class AudioStreamingDriver: StreamingAudioDriver, AudioPlayerDelegate, @unchecked Sendable {
    private let player: AudioPlayer
    private let gain = AVAudioUnitEQ(numberOfBands: 0)
    private let callbackLock = NSLock()
    private var callback: (@Sendable (StreamingDriverEvent) -> Void)?
    private var identities: [(AudioEntryId, UUID)] = []

    init() {
        player = AudioPlayer(configuration: AudioPlayerConfiguration(
            flushQueueOnSeek: true,
            bufferSizeInSeconds: 20,
            secondsRequiredToStartPlaying: 0.5,
            gracePeriodAfterSeekInSeconds: 0.5,
            secondsRequiredToStartPlayingAfterBufferUnderrun: 1,
            enableLogs: false
        ))
        player.loopMode = .off // Repeat belongs to PlayerService, including authenticated URLs.
        player.attach(node: gain)
        player.delegate = self
    }

    var onEvent: (@Sendable (StreamingDriverEvent) -> Void)? {
        get { callbackLock.withLock { callback } }
        set { callbackLock.withLock { callback = newValue } }
    }

    var state: AudioEngineState { Self.engineState(player.state) }
    var position: Double { player.progress }
    var duration: Double { player.duration }
    var renderedFrames: Int { player.framesPlayed }
    var isSeekable: Bool { player.isSeekable && player.duration > 0 }
    var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }
    var muted: Bool {
        get { player.muted }
        set { player.muted = newValue }
    }

    func applyGain(dB: Float) { gain.globalGain = min(24, max(-96, dB.isFinite ? dB : 0)) }
    func play(url: URL, headers: [String: String]) { player.play(url: url, headers: headers) }
    func queue(url: URL, headers: [String: String]) { player.queue(url: url, headers: headers) }
    func pause() { player.pause() }
    func resume() { player.resume() }
    func stop() { player.stop() }
    func seek(to seconds: Double) { player.seek(to: seconds) }

    private func emit(_ event: StreamingDriverEvent) { onEvent?(event) }

    private func identity(_ entry: AudioEntryId) -> UUID {
        callbackLock.withLock {
            if let existing = identities.first(where: { $0.0 == entry }) { return existing.1 }
            // AudioEntryId's equality includes an upstream UUID, even for identical URLs.
            let id = UUID()
            identities.append((entry, id))
            if identities.count > 8 { identities.removeFirst() }
            return id
        }
    }

    private static func engineState(_ state: AudioPlayerState) -> AudioEngineState {
        switch state {
        case .playing: .playing
        case .running, .bufferring: .buffering
        case .paused: .paused
        case .error: .error
        case .ready, .stopped, .disposed: .stopped
        }
    }

    func audioPlayerDidStartPlaying(player: AudioPlayer, with entryId: AudioEntryId) {
        emit(.started(identity(entryId)))
    }
    func audioPlayerDidFinishBuffering(player: AudioPlayer, with entryId: AudioEntryId) {}
    func audioPlayerStateChanged(player: AudioPlayer, with newState: AudioPlayerState, previous: AudioPlayerState) {
        // Main-queue callbacks can lag behind a pause, seek, or stop.
        guard newState == player.state else { return }
        emit(.state(Self.engineState(newState)))
    }
    func audioPlayerDidFinishPlaying(player: AudioPlayer, entryId: AudioEntryId,
                                    stopReason: AudioPlayerStopReason, progress: Double, duration: Double) {
        // Native queue transitions report .none; the final entry reports .eof.
        emit(.finished(identity(entryId), natural: stopReason == .eof || stopReason == .none,
                       position: progress))
    }
    func audioPlayerUnexpectedError(player: AudioPlayer, error: AudioPlayerError) {
        let failure: AudioEngineFailure
        switch error {
        case .networkError(.failure(let underlying)):
            failure = AudioEngineFailure(error: underlying)
        case .networkError(.serverError):
            failure = AudioEngineFailure(error: URLError(.badServerResponse))
        case .networkError(.missingData), .dataNotFound:
            failure = AudioEngineFailure(error: URLError(.zeroByteResource))
        case .streamParseBytesFailure, .codecError,
             .audioSystemError(.codecError), .audioSystemError(.fileStreamError),
             .audioSystemError(.converterError):
            failure = AudioEngineFailure(error: NSError(domain: AVFoundationErrorDomain,
                                                        code: AVError.decodeFailed.rawValue))
        case .audioSystemError, .other:
            failure = AudioEngineFailure(error: NSError(domain: AVFoundationErrorDomain,
                                                        code: AVError.unknown.rawValue))
        }
        emit(.failed(failure))
    }
    func audioPlayerDidCancel(player: AudioPlayer, queuedItems: [AudioEntryId]) {}
    func audioPlayerDidReadMetadata(player: AudioPlayer, metadata: [String: String]) {}
}
