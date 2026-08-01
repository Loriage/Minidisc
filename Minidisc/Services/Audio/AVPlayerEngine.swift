import Accelerate
import AVFoundation
import Foundation
import MediaToolbox
import OSLog
import Synchronization

/// The system engine: two AVFoundation `AVPlayer` decks with role swapping, so decoding runs on
/// Apple's hardware path (bit-perfect lossless without the software-decode crackle) AND transitions
/// can truly overlap. The next track pre-buffers on the standby deck; at a transition the decks either
/// butt-splice (gapless) or blend with an equal-power ramp (real crossfade — both tracks audible).
/// Conforms to `AudioEngine`; `PlayerService` keeps all orchestration.
///
/// Threading: control methods arrive from the `PlayerService` actor, KVO/notification/ramp callbacks
/// on other threads; a recursive lock guards the deck roles and transition state. ReplayGain cuts use
/// each deck's volume; boosts use an `MTAudioProcessingTap` because `AVPlayer.volume` cannot exceed 1.
nonisolated final class AVPlayerEngine: AudioEngine, @unchecked Sendable {
    private enum ReplayGainDeck: Sendable {
        case a
        case b
    }

    /// Identifies the exact physical deck load for which an asynchronous tap install was requested.
    /// Deck roles may swap while AVFoundation loads the audio track, so neither "active" nor
    /// "standby" is a stable identity across the suspension.
    private struct ReplayGainInstallRequest: Sendable {
        let deck: ReplayGainDeck
        let trackID: String
        let generation: UInt64
    }

    private let lock = NSRecursiveLock()
    private weak var storedDelegate: AudioEngineDelegate?

    var delegate: AudioEngineDelegate? {
        get { lock.withLock { storedDelegate } }
        set { lock.withLock { storedDelegate = newValue } }
    }

    private let deckA = AVPlayer()
    private let deckB = AVPlayer()
    private let contextA = ReplayGainTapContext()
    private let contextB = ReplayGainTapContext()
    /// Accessed only while `lock` is held. Separate counters allow both physical decks to prepare
    /// their taps concurrently without one deck invalidating the other's request.
    private var replayGainGenerationA: UInt64 = 0
    private var replayGainGenerationB: UInt64 = 0
    /// Accessed only while `lock` is held.
    private var replayGainTaskA: Task<Void, Never>?
    private var replayGainTaskB: Task<Void, Never>?
    private var activeIsA = true
    private var activePlayer: AVPlayer { activeIsA ? deckA : deckB }
    private var standbyPlayer: AVPlayer { activeIsA ? deckB : deckA }
    private var activeContext: ReplayGainTapContext { activeIsA ? contextA : contextB }
    private var standbyContext: ReplayGainTapContext { activeIsA ? contextB : contextA }

    private var currentItem: AVPlayerItem?
    private var currentAsset: AVAsset?
    private var currentTrackID: String?
    private var currentPlaybackToken: AudioEnginePlaybackToken?
    private var preloadedItem: AVPlayerItem?
    private var preloadedAsset: AVAsset?
    private var preloadedTrackID: String?
    private var preloadedPlaybackToken: AudioEnginePlaybackToken?
    /// Monotonic within this engine instance. It is deliberately never reset with the decks, so a
    /// callback queued for an item that was stopped can never alias a later load of the same song.
    private var nextPlaybackTokenRawValue: UInt64 = 0
    /// Overlap window for the pending transition (0 = gapless butt-splice).
    private var pendingOverlap: Double = 0
    /// URL of an item the engine already promoted at a hand-off; the next `play` with it adopts.
    private var handedOffTrackID: String?

    /// PlayerService-facing volume (restore mute, user fades). Deck volumes = fadeLevel × ramp.
    private var fadeLevel: Float = 1
    private var rampActive: Float = 1
    private var rampStandby: Float = 1
    private var overlapTimer: DispatchSourceTimer?
    private var overlapStep = 0
    private var overlapSteps = 0
    private var isOverlapping = false
    private let rampQueue = DispatchQueue(label: "minidisc.engine.crossfade")
    /// Authoritative track length from the library metadata. AVPlayer's own `item.duration` is an
    /// estimate that drifts on transcoded/VBR streams, which would arm the overlap at the wrong time.
    private var metadataDuration: Double = 0

    /// Orchestration intent: true between a play/resume and the next pause/stop. What separates
    /// "AVPlayer stopped on its own" (end of file, stall) from "the user pressed pause".
    private var shouldBePlaying = false
    /// Set once per item when the end has been reported, so the end-of-item notification and the
    /// watchdog below can never both advance the queue.
    private var didSignalEnd = false
    private var watchdogTimer: DispatchSourceTimer?
    /// Last playhead reading the watchdog saw, and when it last moved.
    private var lastWatchdogTime: Double = -1
    private var lastWatchdogAdvance = Date()
    private static let watchdogInterval = 500
    /// How close to the track length counts as "the file is over" once the playhead stops moving.
    private static let endOfFileTolerance: Double = 1.5
    /// How long the playhead must stay frozen before the watchdog treats it as final rather than a hitch.
    private static let frozenClockGrace: Double = 1.0

    private var timeControlObservers: [NSKeyValueObservation] = []
    private var statusObserver: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?
    private var standbyStatusObserver: NSKeyValueObservation?
    private var periodicToken: Any?
    private var periodicOwner: AVPlayer?

    init() {
        for deck in [deckA, deckB] {
            deck.automaticallyWaitsToMinimizeStalling = true
            deck.actionAtItemEnd = .pause
        }
        // State events follow the ACTIVE deck only; the standby warming up must not leak states.
        for deck in [deckA, deckB] {
            timeControlObservers.append(deck.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
                guard let self else { return }
                self.lock.lock()
                let isActive = player === self.activePlayer
                let playbackToken = isActive ? self.currentPlaybackToken : nil
                self.lock.unlock()
                guard isActive, let playbackToken else { return }
                switch player.timeControlStatus {
                case .playing:
                    self.delegate?.audioEngineDidChangeState(.playing, playbackToken: playbackToken)
                case .paused:
                    self.delegate?.audioEngineDidChangeState(.paused, playbackToken: playbackToken)
                case .waitingToPlayAtSpecifiedRate:
                    self.delegate?.audioEngineDidChangeState(.buffering, playbackToken: playbackToken)
                @unknown default:                    break
                }
            })
        }
    }

    deinit {
        replayGainTaskA?.cancel()
        replayGainTaskB?.cancel()
        overlapTimer?.cancel()
        watchdogTimer?.cancel()
        clearItemObservers()
        standbyStatusObserver?.invalidate()
        timeControlObservers.forEach { $0.invalidate() }
        if let periodicToken, let periodicOwner {
            periodicOwner.removeTimeObserver(periodicToken)
        }
    }

    // MARK: - Asset construction

    /// Options every asset the engine opens is built with.
    ///
    /// `PreferPreciseDurationAndTiming` is what makes seeking work on lossless. Left at its default,
    /// AVFoundation builds an approximate time/byte map rather than indexing the file, and on raw FLAC
    /// that approximation ignores the container's own seek table — a seek then reports the requested
    /// second while the audio resumes up to a minute away, and the gap never closes. Asking for precise
    /// timing costs more work when the asset is opened, which is the right trade for a player whose
    /// scrubber has to land where the user pointed.
    private static func assetOptions(headers: [String: String]) -> [String: Any] {
        var options: [String: Any] = [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        if !headers.isEmpty {
            options["AVURLAssetHTTPHeaderFieldsKey"] = headers
        }
        return options
    }

    // MARK: - AudioEngine

    @discardableResult
    func play(trackID: String, url: URL, headers: [String: String]) -> AudioEnginePlaybackToken {
        lock.lock()
        defer { lock.unlock() }

        // Adopt a hand-off the engine already performed at the natural end of the previous track.
        if trackID == handedOffTrackID,
           currentItem != nil,
           let currentPlaybackToken {
            handedOffTrackID = nil
            beginPlaying()
            return currentPlaybackToken
        }

        // Manual skip into the preloaded track: promote the warm standby deck right away.
        if trackID == preloadedTrackID, preloadedItem?.status == .readyToPlay {
            promotePreloaded(startPlaying: true)
            // `preloadedItem` had a token before promotion, so this is an internal invariant rather
            // than a recoverable playback failure.
            return currentPlaybackToken!
        }

        // Fresh start — drop both decks.
        resetDecks()
        let asset = AVURLAsset(url: url, options: Self.assetOptions(headers: headers))
        let item = AVPlayerItem(asset: asset)
        attachItemObservers(item)
        currentItem = item
        currentAsset = asset
        currentTrackID = trackID
        let playbackToken = makePlaybackToken()
        currentPlaybackToken = playbackToken
        activePlayer.replaceCurrentItem(with: item)
        applyDeckVolumes()
        beginPlaying()
        installReplayGainTapIfNeeded(context: activeContext, trackID: trackID)
        installPeriodicObserver(on: activePlayer)
        return playbackToken
    }

    func setTrackEndTrim(_ seconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard let item = currentItem else { return }
        guard seconds > 0 else {
            item.forwardPlaybackEndTime = .invalid
            return
        }
        let duration = item.duration.isNumeric ? CMTimeGetSeconds(item.duration) : metadataDuration
        guard duration > seconds else { return }
        // Ending the item early makes AVPlayer post didPlayToEndTime at that point, so the hand-off
        // fires where the music actually stops rather than after the encoder's padding.
        item.forwardPlaybackEndTime = CMTime(seconds: duration - seconds, preferredTimescale: 600)
    }

    func preloadNext(
        trackID: String,
        url: URL,
        headers: [String: String],
        crossfadeDuration: Double,
        leadInTrim: Double,
        replayGainDB: Float
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard currentItem != nil else { return }
        if trackID == preloadedTrackID {
            pendingOverlap = crossfadeDuration
            return
        }
        clearPreloadedDeck()
        let asset = AVURLAsset(url: url, options: Self.assetOptions(headers: headers))
        let item = AVPlayerItem(asset: asset)
        standbyPlayer.replaceCurrentItem(with: item)
        preloadedItem = item
        preloadedAsset = asset
        preloadedTrackID = trackID
        preloadedPlaybackToken = makePlaybackToken()
        pendingOverlap = crossfadeDuration
        standbyContext.gain = pow(10, replayGainDB / 20)
        applyDeckVolumes()
        installReplayGainTapIfNeeded(context: standbyContext, trackID: trackID)
        // Preroll once ready so the hand-off starts render-tight, and park the playhead past the
        // track's silent lead-in first — seeking after the deck is audible would be heard.
        standbyStatusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard item === self.preloadedItem else { return }
            if item.status == .failed {
                Logger.player.warning("[ENGINE] standby preload failed — falling back to a cold transition")
                self.clearPreloadedDeck()
                return
            }
            guard item.status == .readyToPlay else { return }
            Logger.player.info(
                "[CROSSFADE] standby ready track='\(self.preloadedTrackID ?? "unknown", privacy: .public)' overlap=\(self.pendingOverlap, format: .fixed(precision: 1))s"
            )
            if leadInTrim > 0 {
                item.seek(
                    to: CMTime(seconds: leadInTrim, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero
                ) { [weak self] _ in
                    self?.lock.lock()
                    if item === self?.preloadedItem { self?.standbyPlayer.preroll(atRate: 1) { _ in } }
                    self?.lock.unlock()
                }
            } else {
                self.standbyPlayer.preroll(atRate: 1) { _ in }
            }
        }
    }

    func cancelPreload() {
        lock.lock()
        defer { lock.unlock() }
        clearPreloadedDeck()
        currentItem?.forwardPlaybackEndTime = .invalid
    }

    func pause() {
        lock.lock()
        defer { lock.unlock() }
        cancelOverlap()
        shouldBePlaying = false
        stopWatchdog()
        activePlayer.pause()
    }

    func resume() {
        lock.lock()
        defer { lock.unlock() }
        beginPlaying()
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        resetDecks()
    }

    func seek(to seconds: Double) async -> Bool {
        let (player, item) = lock.withLock {
            cancelOverlap()
            // A seek moves the playhead on its own; without a fresh baseline the watchdog would read the
            // jump as a frozen clock (or, seeking backwards, as one that never advanced).
            resetWatchdogBaseline()
            didSignalEnd = false
            return (activePlayer, currentItem)
        }

        let finished = await withCheckedContinuation { continuation in
            // Zero tolerance, always. A tolerance does not bound how far the playhead ends up from the
            // target — it grants AVFoundation permission to jump to a position it *estimates* is within
            // range. On raw FLAC that estimate comes from a time/byte map the framework builds without
            // reading the file's seek table, and it can be a minute off: the clock reports the requested
            // second while the audio resumes somewhere else entirely, and the two never resync. Forcing
            // an exact landing makes it verify by decoding instead of guessing.
            player.seek(
                to: CMTime(seconds: seconds, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            ) { completed in
                continuation.resume(returning: completed)
            }
        }

        return lock.withLock {
            finished && item != nil && item === currentItem && player === activePlayer
        }
    }

    var volume: Float {
        get {
            lock.lock()
            defer { lock.unlock() }
            return fadeLevel
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            fadeLevel = newValue
            applyDeckVolumes()
        }
    }

    func applyReplayGain(dB: Float) {
        lock.lock()
        defer { lock.unlock() }
        activeContext.gain = pow(10, dB / 20)
        applyDeckVolumes()
        if currentItem != nil, currentAsset != nil, let trackID = currentTrackID {
            installReplayGainTapIfNeeded(context: activeContext, trackID: trackID)
        }
    }

    var progress: Double {
        lock.lock()
        defer { lock.unlock() }
        let time = activePlayer.currentTime()
        return time.isNumeric ? CMTimeGetSeconds(time) : 0
    }

    var duration: Double {
        lock.lock()
        defer { lock.unlock() }
        guard let duration = currentItem?.duration, duration.isNumeric else { return 0 }
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite && seconds > 0 ? seconds : 0
    }

    var isSeekable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return currentItem?.seekableTimeRanges.isEmpty == false
    }

    /// Idle and ready to start a fresh source (nothing loaded) — the cold-restore path checks this.
    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return currentItem == nil
    }

    // MARK: - Transition machinery (all called with the lock held)

    /// Watches the active deck's clock; when the remaining time enters the overlap window, starts
    /// the blend.
    private func installPeriodicObserver(on player: AVPlayer) {
        if let periodicToken, let periodicOwner {
            periodicOwner.removeTimeObserver(periodicToken)
        }
        periodicOwner = player
        periodicToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 4),
            queue: .main
        ) { [weak self] _ in
            self?.overlapTick()
        }
    }

    func setTrackDuration(_ seconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        metadataDuration = seconds
    }

    private func overlapTick() {
        lock.lock()
        defer { lock.unlock() }
        guard !isOverlapping, pendingOverlap > 0,
              let preloadedItem, preloadedItem.status == .readyToPlay,
              activePlayer.timeControlStatus == .playing,
              let item = currentItem else { return }
        let itemDuration = item.duration.isNumeric ? CMTimeGetSeconds(item.duration) : 0
        let trackDuration = metadataDuration > 0 ? metadataDuration : itemDuration
        guard trackDuration > 0 else { return }
        let remaining = trackDuration - CMTimeGetSeconds(activePlayer.currentTime())
        guard remaining > 0, remaining <= pendingOverlap else { return }
        beginOverlap(duration: min(pendingOverlap, remaining))
    }

    /// Starts the standby deck at zero and blends both decks with an equal-power ramp — both tracks
    /// audible for `duration` seconds. The active deck finishes naturally; `finalizeAdvance` swaps.
    private func beginOverlap(duration: Double) {
        Logger.player.info("[CROSSFADE] overlap started duration=\(duration, format: .fixed(precision: 2))s")
        isOverlapping = true
        rampStandby = 0
        applyDeckVolumes()
        standbyPlayer.play()
        overlapStep = 0
        overlapSteps = max(1, Int(duration / 0.05))
        let timer = DispatchSource.makeTimerSource(queue: rampQueue)
        timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            self?.overlapRampTick()
        }
        overlapTimer = timer
        timer.resume()
    }

    private func overlapRampTick() {
        var endedPlaybackToken: AudioEnginePlaybackToken?
        lock.lock()
        defer {
            lock.unlock()
            if let endedPlaybackToken {
                delegate?.audioEngineDidReachEndOfTrack(playbackToken: endedPlaybackToken)
            }
        }
        guard isOverlapping, overlapTimer != nil else { return }
        overlapStep += 1
        let x = Float(min(overlapStep, overlapSteps)) / Float(overlapSteps)
        rampStandby = sin(x * .pi / 2)
        rampActive = cos(x * .pi / 2)
        applyDeckVolumes()
        if overlapStep >= overlapSteps {
            Logger.player.info("[CROSSFADE] overlap completed")
            overlapTimer?.cancel()
            overlapTimer = nil
            // Blend complete — the outgoing deck is silent. Hand off NOW instead of waiting for its
            // (possibly mis-estimated) end-of-file, so the UI advances together with the audio.
            endedPlaybackToken = finalizeAdvance()
        }
    }

    /// Aborts a blend in progress (pause, seek, engine reset): the incoming deck rewinds and stays
    /// preloaded, the active deck returns to full level. The window re-arms via the periodic tick.
    private func cancelOverlap() {
        overlapTimer?.cancel()
        overlapTimer = nil
        if isOverlapping {
            isOverlapping = false
            standbyPlayer.pause()
            standbyPlayer.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        rampActive = 1
        rampStandby = 1
        applyDeckVolumes()
    }

    // MARK: - End-of-track watchdog

    /// Starts the active deck and arms the watchdog. Every path that puts audio back in motion goes
    /// through here so playback intent and the watchdog can never drift apart.
    private func beginPlaying() {
        shouldBePlaying = true
        activePlayer.play()
        startWatchdog()
    }

    private func startWatchdog() {
        watchdogTimer?.cancel()
        resetWatchdogBaseline()
        let timer = DispatchSource.makeTimerSource(queue: rampQueue)
        timer.schedule(
            deadline: .now() + .milliseconds(Self.watchdogInterval),
            repeating: .milliseconds(Self.watchdogInterval)
        )
        timer.setEventHandler { [weak self] in
            self?.watchdogTick()
        }
        watchdogTimer = timer
        timer.resume()
    }

    private func stopWatchdog() {
        watchdogTimer?.cancel()
        watchdogTimer = nil
    }

    private func resetWatchdogBaseline() {
        lastWatchdogTime = -1
        lastWatchdogAdvance = Date()
    }

    /// `didPlayToEndTimeNotification` is the only end-of-file signal AVPlayer gives us, and a streamed
    /// item that stalls on its last packets — routine once the app is backgrounded and the network is
    /// throttled — can simply never post it. Nothing downstream notices: the engine reports `.paused`,
    /// which PlayerService does not act on, so the queue stops for good with the UI still on "playing".
    ///
    /// So the end is re-derived from the clock instead of trusted to a single notification. The rule is
    /// deliberately narrow: act only when playback is *meant* to be running, the playhead has stopped
    /// moving for longer than a hitch, AND it stopped within a whisker of the track length. A mid-track
    /// buffer stall leaves the playhead far from the end and is left alone for AVPlayer to recover from;
    /// a user pause clears `shouldBePlaying` and stops the timer outright.
    private func watchdogTick() {
        var endedPlaybackToken: AudioEnginePlaybackToken?
        lock.lock()
        defer {
            lock.unlock()
            if let endedPlaybackToken {
                delegate?.audioEngineDidReachEndOfTrack(playbackToken: endedPlaybackToken)
            }
        }
        guard shouldBePlaying, !didSignalEnd, let item = currentItem else { return }

        let itemDuration = item.duration.isNumeric ? CMTimeGetSeconds(item.duration) : 0
        let trackDuration = metadataDuration > 0 ? metadataDuration : itemDuration
        // A live stream has no length to compare against, so it is never "finished".
        guard trackDuration > 0 else { return }

        let time = activePlayer.currentTime()
        let position = time.isNumeric ? CMTimeGetSeconds(time) : 0

        if position > lastWatchdogTime + 0.05 {
            lastWatchdogTime = position
            lastWatchdogAdvance = Date()
            return
        }
        // `position > 0` keeps a track that never started (still opening the stream, failed to load)
        // out of this path — that is an error for PlayerService to handle, not a finished track.
        let remaining = trackDuration - position
        guard position > 0,
              Date().timeIntervalSince(lastWatchdogAdvance) >= Self.frozenClockGrace,
              remaining >= -Self.endOfFileTolerance,
              remaining <= Self.endOfFileTolerance else { return }

        let reading = String(format: "%.2fs of %.2fs", position, trackDuration)
        Logger.player.warning(
            "[ENGINE] end-of-track watchdog fired — AVPlayer never reported EOF (\(reading, privacy: .public))"
        )
        endedPlaybackToken = finalizeAdvance()
    }

    /// The current item played to its end. With a preloaded next: retire the finished deck, promote
    /// the standby (already blending in a crossfade, or started now for gapless), then tell
    /// PlayerService — whose confirming `play` adopts the promoted deck via `handedOffTrackID`.
    @discardableResult
    private func finalizeAdvance() -> AudioEnginePlaybackToken? {
        // The notification, the crossfade ramp and the watchdog all land here, and any two of them can
        // fire for the same track — one advance per item.
        guard !didSignalEnd, let endedPlaybackToken = currentPlaybackToken else { return nil }
        didSignalEnd = true
        guard let preloadedItem, preloadedItem.status == .readyToPlay,
              let trackID = preloadedTrackID else {
            clearPreloadedDeck()
            return endedPlaybackToken
        }
        let wasOverlapping = isOverlapping
        handedOffTrackID = trackID
        promotePreloaded(startPlaying: !wasOverlapping)
        return endedPlaybackToken
    }

    /// Swaps deck roles and makes the preloaded item current.
    private func promotePreloaded(startPlaying: Bool) {
        overlapTimer?.cancel()
        overlapTimer = nil
        isOverlapping = false
        clearItemObservers()
        standbyStatusObserver?.invalidate()
        standbyStatusObserver = nil
        activePlayer.pause()
        activePlayer.replaceCurrentItem(with: nil)
        activeContext.tapInstalled = false
        activeIsA.toggle()
        currentItem = preloadedItem
        currentAsset = preloadedAsset
        currentTrackID = preloadedTrackID
        currentPlaybackToken = preloadedPlaybackToken
        preloadedItem = nil
        preloadedAsset = nil
        preloadedTrackID = nil
        preloadedPlaybackToken = nil
        pendingOverlap = 0
        metadataDuration = 0
        rampActive = 1
        rampStandby = 1
        applyDeckVolumes()
        if let item = currentItem {
            attachItemObservers(item)
        }
        // The promoted deck carries on playing: either it was started here, or it has been audible
        // since the crossfade began. Either way the new item starts its own end-detection cycle.
        didSignalEnd = false
        shouldBePlaying = true
        if startPlaying {
            activePlayer.play()
        }
        startWatchdog()
        installPeriodicObserver(on: activePlayer)
    }

    private func resetDecks() {
        overlapTimer?.cancel()
        overlapTimer = nil
        isOverlapping = false
        shouldBePlaying = false
        didSignalEnd = false
        stopWatchdog()
        clearItemObservers()
        standbyStatusObserver?.invalidate()
        standbyStatusObserver = nil
        deckA.pause()
        deckB.pause()
        deckA.replaceCurrentItem(with: nil)
        deckB.replaceCurrentItem(with: nil)
        currentItem = nil
        currentAsset = nil
        currentTrackID = nil
        currentPlaybackToken = nil
        preloadedItem = nil
        preloadedAsset = nil
        preloadedTrackID = nil
        preloadedPlaybackToken = nil
        handedOffTrackID = nil
        pendingOverlap = 0
        metadataDuration = 0
        rampActive = 1
        rampStandby = 1
        contextA.tapInstalled = false
        contextB.tapInstalled = false
        applyDeckVolumes()
    }

    /// Clears only the standby role. Caller holds `lock`.
    private func clearPreloadedDeck() {
        standbyStatusObserver?.invalidate()
        standbyStatusObserver = nil
        standbyPlayer.pause()
        standbyPlayer.replaceCurrentItem(with: nil)
        standbyContext.tapInstalled = false
        preloadedItem = nil
        preloadedAsset = nil
        preloadedTrackID = nil
        preloadedPlaybackToken = nil
        pendingOverlap = 0
    }

    /// Caller holds `lock`.
    private func makePlaybackToken() -> AudioEnginePlaybackToken {
        nextPlaybackTokenRawValue &+= 1
        return AudioEnginePlaybackToken(rawValue: nextPlaybackTokenRawValue)
    }

    private func applyDeckVolumes() {
        activePlayer.volume = fadeLevel * rampActive * activeContext.deckVolumeScale
        standbyPlayer.volume = fadeLevel * rampStandby * standbyContext.deckVolumeScale
    }

    // MARK: - Per-item observers

    private func attachItemObservers(_ item: AVPlayerItem) {
        clearItemObservers()
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self, item.status == .failed else { return }
            let message = item.error?.localizedDescription ?? "AVPlayer item failed"
            let playbackToken = self.lock.withLock {
                item === self.currentItem ? self.currentPlaybackToken : nil
            }
            guard let playbackToken else { return }
            self.delegate?.audioEngineDidError(message, playbackToken: playbackToken)
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            guard let self else { return }
            self.lock.lock()
            // A crossfade hand-off retires the outgoing deck before its item reports EOF, and removing
            // a block observer does not cancel a notification already queued on the main queue. Without
            // this identity check that late arrival would advance the queue a second time, skipping the
            // track that just took over.
            let endedPlaybackToken: AudioEnginePlaybackToken? = if let item, item === self.currentItem {
                self.finalizeAdvance()
            } else {
                nil
            }
            self.lock.unlock()
            if let endedPlaybackToken {
                self.delegate?.audioEngineDidReachEndOfTrack(playbackToken: endedPlaybackToken)
            }
        }
        // A mid-stream network failure (connection drop, server hiccup) — surface it so PlayerService
        // can route to its error handling (radio failover, or a retry/timeout state).
        failObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self, weak item] note in
            guard let self else { return }
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            let message = error?.localizedDescription ?? "Playback failed"
            let playbackToken: AudioEnginePlaybackToken? = self.lock.withLock {
                guard let item, item === self.currentItem else { return nil }
                return self.currentPlaybackToken
            }
            guard let playbackToken else { return }
            self.delegate?.audioEngineDidError(message, playbackToken: playbackToken)
        }
    }

    private func clearItemObservers() {
        statusObserver?.invalidate()
        statusObserver = nil
        for observer in [endObserver, failObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
        endObserver = nil
        failObserver = nil
    }

    // MARK: - ReplayGain tap install

    private func installReplayGainTapIfNeeded(context: ReplayGainTapContext, trackID: String) {
        let previousTask: Task<Void, Never>?
        if context === contextA {
            previousTask = replayGainTaskA
        } else {
            previousTask = replayGainTaskB
        }
        previousTask?.cancel()

        guard Self.requiresReplayGainTap(linearGain: context.gain) else { return }
        // `item` and `asset` are intentionally not captured by the Task: both are non-Sendable
        // Objective-C references. The asynchronous worker resolves them from the locked engine state.
        let request = makeReplayGainInstallRequest(context: context, trackID: trackID)
        let task = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            await self?.performReplayGainTapInstall(request)
        }
        switch request.deck {
        case .a:
            replayGainTaskA = task
        case .b:
            replayGainTaskB = task
        }
    }

    /// Creates a request for the physical deck represented by `context`. Caller holds `lock`.
    private func makeReplayGainInstallRequest(
        context: ReplayGainTapContext,
        trackID: String
    ) -> ReplayGainInstallRequest {
        if context === contextA {
            replayGainGenerationA &+= 1
            return ReplayGainInstallRequest(
                deck: .a,
                trackID: trackID,
                generation: replayGainGenerationA
            )
        } else {
            replayGainGenerationB &+= 1
            return ReplayGainInstallRequest(
                deck: .b,
                trackID: trackID,
                generation: replayGainGenerationB
            )
        }
    }

    /// Loads the audio track without holding the engine lock, then revalidates deck identity before
    /// mutating AVPlayerItem. A preload promotion can legitimately swap roles during the `await`.
    @MainActor
    private func performReplayGainTapInstall(_ request: ReplayGainInstallRequest) async {
        let asset = lock.withLock {
            replayGainTarget(for: request)?.asset
        }
        guard let asset else { return }

        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else {
            guard !Task.isCancelled else { return }
            Logger.player.warning(
                "[REPLAYGAIN] no audio track available for '\(request.trackID, privacy: .public)'"
            )
            return
        }
        guard !Task.isCancelled else { return }

        let installed = lock.withLock {
            guard let target = replayGainTarget(for: request),
                  Self.requiresReplayGainTap(linearGain: target.context.gain),
                  !target.context.tapInstalled,
                  let tap = Self.makeReplayGainTap(context: target.context) else { return false }

            let params = AVMutableAudioMixInputParameters(track: track)
            params.audioTapProcessor = tap
            let mix = AVMutableAudioMix()
            mix.inputParameters = [params]
            target.item.audioMix = mix
            target.context.tapInstalled = true
            applyDeckVolumes()
            return true
        }
        if installed {
            Logger.player.info(
                "[REPLAYGAIN] audio tap installed for '\(request.trackID, privacy: .public)'"
            )
        }
    }

    /// Resolves a physical deck after checking both its request generation and current logical role.
    /// Caller holds `lock`.
    private func replayGainTarget(
        for request: ReplayGainInstallRequest
    ) -> (item: AVPlayerItem, asset: AVAsset, context: ReplayGainTapContext)? {
        let context: ReplayGainTapContext
        let generation: UInt64
        switch request.deck {
        case .a:
            context = contextA
            generation = replayGainGenerationA
        case .b:
            context = contextB
            generation = replayGainGenerationB
        }
        guard generation == request.generation else { return nil }

        if context === activeContext,
           currentTrackID == request.trackID,
           let currentItem,
           let currentAsset {
            return (currentItem, currentAsset, context)
        }
        if context === standbyContext,
           preloadedTrackID == request.trackID,
           let preloadedItem,
           let preloadedAsset {
            return (preloadedItem, preloadedAsset, context)
        }
        return nil
    }

    nonisolated static func requiresReplayGainTap(linearGain: Float) -> Bool {
        linearGain > 1
    }

    nonisolated static func replayGainDeckVolumeScale(linearGain: Float, tapInstalled: Bool) -> Float {
        tapInstalled ? 1 : min(linearGain, 1)
    }

    private static func makeReplayGainTap(context: ReplayGainTapContext) -> MTAudioProcessingTap? {
        let clientInfo = UnsafeMutableRawPointer(Unmanaged.passRetained(context).toOpaque())
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: clientInfo,
            init: replayGainTapInit,
            finalize: replayGainTapFinalize,
            prepare: nil,
            unprepare: nil,
            process: replayGainTapProcess
        )
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard status == noErr, let tap else {
            // Balance the passRetained above — finalize will never run for a failed create.
            Unmanaged<ReplayGainTapContext>.fromOpaque(clientInfo).release()
            return nil
        }
        return tap
    }
}

// MARK: - ReplayGain audio tap

/// Shared between the engine and the realtime render callback. The Float bit pattern is atomic so
/// the callback never takes a lock and the access remains valid under Swift's memory model.
private nonisolated final class ReplayGainTapContext: @unchecked Sendable {
    private let gainBits = Atomic<UInt32>(Float(1).bitPattern)
    private let tapInstalledBits = Atomic<UInt8>(0)

    var gain: Float {
        get { Float(bitPattern: gainBits.load(ordering: .relaxed)) }
        set { gainBits.store(newValue.bitPattern, ordering: .relaxed) }
    }

    var tapInstalled: Bool {
        get { tapInstalledBits.load(ordering: .relaxed) == 1 }
        set { tapInstalledBits.store(newValue ? 1 : 0, ordering: .relaxed) }
    }

    var deckVolumeScale: Float {
        AVPlayerEngine.replayGainDeckVolumeScale(linearGain: gain, tapInstalled: tapInstalled)
    }
}

private nonisolated func replayGainTapInit(
    tap: MTAudioProcessingTap,
    clientInfo: UnsafeMutableRawPointer?,
    tapStorageOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>
) {
    tapStorageOut.pointee = clientInfo
}

private nonisolated func replayGainTapFinalize(tap: MTAudioProcessingTap) {
    Unmanaged<ReplayGainTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
}

private nonisolated func replayGainTapProcess(
    tap: MTAudioProcessingTap,
    numberFrames: CMItemCount,
    flags: MTAudioProcessingTapFlags,
    bufferListInOut: UnsafeMutablePointer<AudioBufferList>,
    numberFramesOut: UnsafeMutablePointer<CMItemCount>,
    flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>
) {
    let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut)
    guard status == noErr else { return }
    let context = Unmanaged<ReplayGainTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    var gain = context.gain
    guard gain != 1.0 else { return }
    // Tap audio is 32-bit float; a flat multiply is correct whether channels are interleaved or not.
    for buffer in UnsafeMutableAudioBufferListPointer(bufferListInOut) {
        guard let data = buffer.mData else { continue }
        let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        let samples = data.assumingMemoryBound(to: Float.self)
        vDSP_vsmul(samples, 1, &gain, samples, 1, vDSP_Length(count))
    }
}
