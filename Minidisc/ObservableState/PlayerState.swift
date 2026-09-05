import Foundation
import Observation
import SwiftSonic

/// Observable UI state for playback. Updated by PlayerService via MainActor.run.
/// Single source of truth consumed by MiniPlayer, FullPlayer, NowPlayingService,
/// and (v1.2) CarPlay scene — no duplicated playback state anywhere else.
@Observable
@MainActor
final class PlayerState {
    /// Internal identity of the current queue session. Async producers verify it
    /// before committing results so an old session cannot append into a replacement.
    @ObservationIgnored var queueGeneration: UInt64 = 0
    /// Every structural queue edit invalidates row actions captured before that edit, including
    /// edits involving two occurrences of the same song.
    @ObservationIgnored private(set) var queueRevision: UInt64 = 0
    var currentTrack: DisplayableSong?
    var queue: [DisplayableSong] = [] {
        didSet { queueRevision &+= 1 }
    }
    var currentIndex: Int = 0
    var playbackState: PlaybackState = .idle {
        didSet {
            switch playbackState {
            case .loading:
                // Each selected track gets its own presentation grace period.
                waitingReason = nil
                waitingReason = .loading
            case .playing:
                if oldValue == .paused { waitingReason = .loading }
            case .idle, .paused, .error: waitingReason = nil
            }
        }
    }
    /// Waiting is presentation state, independent from the listener's Play/Pause intent.
    var waitingReason: PlaybackWaitingReason? {
        didSet {
            guard oldValue != waitingReason else { return }
            updateWaitingMessage()
        }
    }
    private var visibleWaitingReason: PlaybackWaitingReason?
    @ObservationIgnored private var waitingMessageTask: Task<Void, Never>?
    @ObservationIgnored private let waitingMessageDelay: Duration
    var wantsPlayback: Bool { playbackState == .playing || playbackState == .loading }

    var playbackStatusMessage: String? {
        if wantsPlayback, let visibleWaitingReason { return visibleWaitingReason.title }
        if case .error(let error) = playbackState { return UserFacingError.from(error).displayMessage }
        if !isPlaybackAvailable { return String(localized: "Reconnect to resume") }
        return nil
    }
    var position: TimeInterval = 0
    var duration: TimeInterval = 0
    var repeatMode: RepeatMode = .off
    var isShuffled: Bool = false
    /// False when a restored track cannot be resolved (offline + streamed only).
    /// Resets to true when normal playback starts.
    var isPlaybackAvailable: Bool = true
    /// Non-nil when the player is in live stream mode (radio playback).
    /// Mutually exclusive with active queue playback: starting play(tracks:) clears this to nil.
    var currentRadio: InternetRadioStation?
    /// True when a radio is the current playback source. Equivalent to currentRadio != nil.
    var isLiveStream: Bool { currentRadio != nil }
    /// True when the current playback session was started via Smart Shuffle.
    /// Survives skips and pauses; resets on new explicit play, radio, stop, or cold start.
    var isSmartShuffleActive: Bool = false
    /// User preference: when enabled, the player automatically appends a fresh smart shuffle batch
    /// when ≤15 tracks remain. Suppressed by loop mode and live stream mode. AppContainer loads the
    /// persisted initial value from PlaybackPreferences.
    var isAutoExtendEnabled: Bool
    /// Boundary between user-intentional queue tracks and auto-extended tracks.
    /// `nil` when no auto-extend has occurred in the current session.
    /// When set, indices `[0..<originalQueueEndIndex]` are user-intentional (album, playlist, or initial
    /// smart shuffle batch), and indices `[originalQueueEndIndex...]` are added by auto-extend.
    /// Reset to `nil` on play(tracks:), playRadio(), stop().
    var originalQueueEndIndex: Int?

    init(isAutoExtendEnabled: Bool = false, waitingMessageDelay: Duration = .milliseconds(700)) {
        self.isAutoExtendEnabled = isAutoExtendEnabled
        self.waitingMessageDelay = waitingMessageDelay
    }

    private func updateWaitingMessage() {
        waitingMessageTask?.cancel()
        waitingMessageTask = nil
        guard let reason = waitingReason, wantsPlayback else {
            visibleWaitingReason = nil
            return
        }
        if visibleWaitingReason != nil {
            visibleWaitingReason = reason
            return
        }
        let delay = waitingMessageDelay
        waitingMessageTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) }
            catch { return }
            guard let self, self.wantsPlayback, self.waitingReason == reason else { return }
            self.visibleWaitingReason = reason
            self.waitingMessageTask = nil
        }
    }

    // MARK: - Derived UI state

    /// SF Symbol name and active-mode flag for the queue button, in priority order:
    /// Loop One > Loop All > Shuffle > Smart Shuffle > default queue list.
    var queueIcon: (symbolName: String, isActiveMode: Bool) {
        if repeatMode == .one    { return ("repeat.1", true) }
        if repeatMode == .all    { return ("repeat",   true) }
        if isShuffled            { return ("shuffle",  true) }
        if isSmartShuffleActive  { return ("sparkles", true) }
        return ("list.bullet", false)
    }

    /// Badge symbol to overlay on the iOS queue icon, or nil when no mode is active.
    /// Priority: Loop One > Loop All > Shuffle > Smart Shuffle.
    var queueModeBadge: String? {
        if repeatMode == .one   { return "repeat.1" }
        if repeatMode == .all   { return "repeat" }
        if isShuffled           { return "shuffle" }
        if isSmartShuffleActive { return "sparkles" }
        return nil
    }
}
