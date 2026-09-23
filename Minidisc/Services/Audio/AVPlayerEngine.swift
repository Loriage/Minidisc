import Accelerate
import AVFoundation
import Foundation
import MediaToolbox
import OSLog
import Synchronization

/// Sequential playback keeps one active queue; only crossfades prepare a second audible deck.
/// A recursive lock protects deck roles and transition state across control calls and callbacks.
/// ReplayGain boosts use an audio processing tap because AVPlayer.volume cannot exceed 1.
nonisolated final class AVPlayerEngine: AudioEngine, @unchecked Sendable {
    private enum StandbyPreparationState {
        case idle
        case preparing
        case ready
    }

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

    private let playerFactory: @Sendable () -> AVQueuePlayer
    private var deckA: AVQueuePlayer
    private var deckB: AVQueuePlayer
    private var contextA = ReplayGainTapContext()
    private var contextB = ReplayGainTapContext()
    /// Accessed only while `lock` is held. Separate counters allow both physical decks to prepare
    /// their taps concurrently without one deck invalidating the other's request.
    private var replayGainGenerationA: UInt64 = 0
    private var replayGainGenerationB: UInt64 = 0
    /// Accessed only while `lock` is held.
    private var replayGainTaskA: Task<Void, Never>?
    private var replayGainTaskB: Task<Void, Never>?
    private var activeIsA = true
    private var airPlayActive = false
    private var activePlayer: AVQueuePlayer { activeIsA ? deckA : deckB }
    private var standbyPlayer: AVQueuePlayer { activeIsA ? deckB : deckA }
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
    private var preloadedSourceURL: URL?
    private var preloadedSourceHeaders: [String: String] = [:]
    private var preloadedStartPosition: TimeInterval = 0
    private var preloadedInActiveQueue = false
    private var changingQueue = false
    private var standbyPreparationState: StandbyPreparationState = .idle
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
    private var overlapDuration: TimeInterval = 0
    private var overlapStartedAt: Date?
    private var overlapAwaitingStandbyPlayback = false
    private var isOverlapping = false
    private let rampQueue = DispatchQueue(label: "minidisc.engine.crossfade")
    private var overlapBoundaryToken: Any?
    private var overlapBoundaryOwner: AVPlayer?
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
    private var lastWatchdogTime: Double = -1
    private var lastWatchdogAdvance = Date()
    private static let watchdogInterval = 500
    private static let endOfFileTolerance: Double = 1.5
    private static let frozenClockGrace: Double = 1.0

    private var timeControlObservers: [NSKeyValueObservation] = []
    private var queueItemObservers: [NSKeyValueObservation] = []
    private var statusObserver: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?
    private var standbyStatusObserver: NSKeyValueObservation?
    private var periodicToken: Any?
    private var periodicOwner: AVPlayer?

    init(playerFactory: @escaping @Sendable () -> AVQueuePlayer = { AVQueuePlayer() }) {
        self.playerFactory = playerFactory
        deckA = playerFactory()
        deckB = playerFactory()
        configurePlayers()
    }

    /// Installs observers on the current physical players, including after a system reset.
    /// Caller holds the lock, except during initialization.
    private func configurePlayers() {
        for deck in [deckA, deckB] {
            deck.automaticallyWaitsToMinimizeStalling = true
            deck.actionAtItemEnd = .pause
            queueItemObservers.append(deck.observe(\.currentItem, options: [.new]) { [weak self] player, _ in
                guard let self else { return }
                let transition = self.lock.withLock {
                    guard !self.changingQueue, player === self.activePlayer,
                          self.preloadedInActiveQueue,
                          let next = self.preloadedItem, player.currentItem === next else { return nil as AudioEngineTrackEnd? }
                    return self.finalizeAdvance()
                }
                if let transition { self.delegate?.audioEngineDidReachEndOfTrack(transition) }
            })
        }
        // State events follow the ACTIVE deck only; the standby warming up must not leak states.
        for deck in [deckA, deckB] {
            timeControlObservers.append(deck.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
                guard let self else { return }
                self.lock.lock()
                let isActive = player === self.activePlayer
                let playbackToken = isActive ? self.currentPlaybackToken : nil
                if !isActive, player === self.standbyPlayer {
                    switch player.timeControlStatus {
                    case .playing:
                        self.startOverlapRampIfPossible()
                    case .paused, .waitingToPlayAtSpecifiedRate:
                        if self.isOverlapping {
                            // A buffering incoming deck must never leave the only audible deck
                            // partially faded. Its media clock freezes, so the ramp resumes from
                            // the same point once AVPlayer renders it again.
                            self.rampActive = 1
                            self.rampStandby = 0
                            self.applyDeckVolumes()
                        }
                    @unknown default:
                        break
                    }
                }
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
        queueItemObservers.forEach { $0.invalidate() }
        if let periodicToken, let periodicOwner {
            periodicOwner.removeTimeObserver(periodicToken)
        }
        if let overlapBoundaryToken, let overlapBoundaryOwner {
            overlapBoundaryOwner.removeTimeObserver(overlapBoundaryToken)
        }
    }

    // MARK: - Asset construction

    /// Precise timing is required for reliable seeks in lossless streams.
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

        // A Next command may beat the failed item's callback to PlayerService. A failed
        // AVPlayer is terminal: replacing its AVPlayerItem is not enough to revive it.
        if activePlayer.status == .failed {
            recreatePlayers()
        }

        if trackID == handedOffTrackID,
           currentItem != nil,
           let currentPlaybackToken {
            handedOffTrackID = nil
            beginPlaying()
            return currentPlaybackToken
        }

        if preloadedInActiveQueue, trackID == preloadedTrackID {
            changingQueue = true
            if activePlayer.currentItem !== preloadedItem { activePlayer.advanceToNextItem() }
            changingQueue = false
            if activePlayer.currentItem === preloadedItem {
                promoteQueuedItem()
                beginPlaying()
                return currentPlaybackToken!
            }
        }

        if !preloadedInActiveQueue, trackID == preloadedTrackID,
           standbyPreparationState == .ready,
           preloadedItem?.status == .readyToPlay {
            promotePreloaded(startPlaying: true)
            // `preloadedItem` had a token before promotion, so this is an internal invariant rather
            // than a recoverable playback failure.
            return currentPlaybackToken!
        }

        resetDecks(preservingActiveItem: true)
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
        return playbackToken
    }

    func preloadNext(
        trackID: String,
        url: URL,
        headers: [String: String],
        crossfadeDuration: Double,
        replayGainDB: Float
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard currentItem != nil else { return }
        if airPlayActive || crossfadeDuration <= 0 {
            enqueueNext(trackID: trackID, url: url, headers: headers, replayGainDB: replayGainDB)
            return
        }
        if trackID == preloadedTrackID, !preloadedInActiveQueue {
            pendingOverlap = crossfadeDuration
            if crossfadeDuration > 0 {
                installTransitionObservers(on: activePlayer)
            } else {
                removeTransitionObservers()
            }
            return
        }
        cancelOverlap()
        clearPreloadedDeck()
        if standbyPlayer.status == .failed {
            // Recreate a failed idle deck only when an actual crossfade needs it.
            timeControlObservers.forEach { $0.invalidate() }
            timeControlObservers.removeAll()
            queueItemObservers.forEach { $0.invalidate() }
            queueItemObservers.removeAll()
            if activeIsA { deckB = playerFactory() } else { deckA = playerFactory() }
            configurePlayers()
        }
        let asset = AVURLAsset(url: url, options: Self.assetOptions(headers: headers))
        let item = AVPlayerItem(asset: asset)
        standbyPlayer.replaceCurrentItem(with: item)
        preloadedItem = item
        preloadedAsset = asset
        preloadedTrackID = trackID
        preloadedPlaybackToken = makePlaybackToken()
        preloadedSourceURL = url
        preloadedSourceHeaders = headers
        preloadedStartPosition = 0
        standbyPreparationState = .preparing
        pendingOverlap = crossfadeDuration
        if crossfadeDuration > 0 {
            installTransitionObservers(on: activePlayer)
        } else {
            removeTransitionObservers()
        }
        standbyContext.gain = pow(10, replayGainDB / 20)
        applyDeckVolumes()
        installReplayGainTapIfNeeded(context: standbyContext, trackID: trackID)
        // Prime the incoming crossfade deck before starting its volume ramp.
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
                "[CROSSFADE] standby item ready track='\(self.preloadedTrackID ?? "unknown", privacy: .public)' overlap=\(self.pendingOverlap, format: .fixed(precision: 1))s"
            )
            self.prerollStandby(item)
        }
    }

    /// `readyToPlay` only means that the item can begin loading. A standby deck becomes eligible
    /// for promotion only after AVPlayer confirms that its media pipeline has actually been primed.
    private func prerollStandby(_ item: AVPlayerItem) {
        guard item === preloadedItem else { return }
        standbyPreparationState = .preparing
        standbyPlayer.preroll(atRate: 1) { [weak self, weak item] succeeded in
            guard let self, let item else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard item === self.preloadedItem else { return }
            guard succeeded else {
                Logger.player.warning("[ENGINE] standby preroll failed — using cold transition")
                self.clearPreloadedDeck()
                return
            }
            self.standbyPreparationState = .ready
            Logger.player.info(
                "[ENGINE] standby preroll completed track='\(self.preloadedTrackID ?? "unknown", privacy: .public)'"
            )
            // The exact overlap boundary may have passed while a slow stream was priming. The
            // periodic fallback computes the remaining playable window and starts safely now.
            if self.pendingOverlap > 0 {
                self.overlapTick()
            }
        }
    }

    func setAirPlayActive(_ active: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard airPlayActive != active else { return }
        cancelPreload()
        airPlayActive = active
    }

    private func enqueueNext(trackID: String, url: URL, headers: [String: String], replayGainDB: Float) {
        guard trackID != preloadedTrackID || !preloadedInActiveQueue else { return }
        cancelOverlap()
        clearPreloadedDeck()
        let asset = AVURLAsset(url: url, options: Self.assetOptions(headers: headers))
        let item = AVPlayerItem(asset: asset)
        guard let currentItem, activePlayer.currentItem === currentItem,
              activePlayer.canInsert(item, after: currentItem) else { return }
        preloadedItem = item
        preloadedAsset = asset
        preloadedTrackID = trackID
        preloadedPlaybackToken = makePlaybackToken()
        preloadedSourceURL = url
        preloadedSourceHeaders = headers
        preloadedInActiveQueue = true
        standbyContext.gain = pow(10, replayGainDB / 20)
        installReplayGainTapIfNeeded(context: standbyContext, trackID: trackID)
        // AVQueuePlayer owns buffering and the natural hand-off, even if the next item is still loading.
        activePlayer.actionAtItemEnd = .advance
        activePlayer.insert(item, after: currentItem)
        standbyStatusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard let self, item.status == .failed else { return }
            self.lock.withLock {
                guard self.preloadedInActiveQueue, item === self.preloadedItem,
                      item !== self.activePlayer.currentItem else { return }
                self.clearPreloadedDeck()
            }
        }
    }

    private func promoteQueuedItem() {
        clearItemObservers()
        replayGainTaskA?.cancel()
        replayGainTaskB?.cancel()
        replayGainGenerationA &+= 1
        replayGainGenerationB &+= 1
        let incomingContext = standbyContext
        if activeIsA {
            contextA = incomingContext
            contextB = ReplayGainTapContext()
        } else {
            contextB = incomingContext
            contextA = ReplayGainTapContext()
        }
        currentItem = preloadedItem
        currentAsset = preloadedAsset
        currentTrackID = preloadedTrackID
        currentPlaybackToken = preloadedPlaybackToken
        preloadedInActiveQueue = false
        clearPreloadedDeck()
        metadataDuration = 0
        didSignalEnd = false
        applyDeckVolumes()
        if let item = currentItem { attachItemObservers(item) }
        if let trackID = currentTrackID { installReplayGainTapIfNeeded(context: activeContext, trackID: trackID) }
        if shouldBePlaying { startWatchdog() }
    }

    func cancelPreload() {
        lock.lock()
        // The native queue can advance before its KVO callback obtains our lock.
        // Preserve that hand-off before discarding the remaining preparation metadata.
        let transition: AudioEngineTrackEnd?
        if preloadedInActiveQueue, let next = preloadedItem, activePlayer.currentItem === next {
            transition = finalizeAdvance()
        } else {
            transition = nil
        }
        // A path change can arrive while the standby deck is already audible in a crossfade.
        // Restore the active deck to full volume and stop the ramp before clearing standby;
        // otherwise the orphaned timer would keep fading the only remaining deck to silence.
        cancelOverlap()
        clearPreloadedDeck()
        lock.unlock()
        if let transition { delegate?.audioEngineDidReachEndOfTrack(transition) }
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
        // Queued pause callbacks can arrive after this deck already resumed/began buffering.
        // Reasserting play there restarts watchdog/overlap work without helping the connection.
        guard !shouldBePlaying || activePlayer.timeControlStatus == .paused else { return }
        beginPlaying()
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        resetDecks()
    }

    func resetAfterMediaServicesReset() {
        lock.withLock { recreatePlayers() }
    }

    /// Caller holds the lock. Discard both decks, their observers, and all pending work
    /// tied to the old media services. Tokens never restart, even if the same song reloads.
    private func recreatePlayers() {
        let activeGain = activeContext.gain
        timeControlObservers.forEach { $0.invalidate() }
        timeControlObservers.removeAll()
        queueItemObservers.forEach { $0.invalidate() }
        queueItemObservers.removeAll()
        replayGainTaskA?.cancel()
        replayGainTaskB?.cancel()
        replayGainTaskA = nil
        replayGainTaskB = nil
        replayGainGenerationA &+= 1
        replayGainGenerationB &+= 1
        resetDecks()
        deckA = playerFactory()
        deckB = playerFactory()
        contextA = ReplayGainTapContext()
        contextB = ReplayGainTapContext()
        activeIsA = true
        contextA.gain = activeGain
        configurePlayers()
        applyDeckVolumes()
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
            // Exact seeks avoid approximate time-to-byte mappings on raw FLAC streams.
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

    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return currentItem == nil
    }

    // MARK: - Transition machinery (all called with the lock held)

    /// A boundary observer starts the blend on the media timeline. The low-frequency periodic
    /// observer remains as a fallback when the standby finishes prerolling after that boundary.
    private func installTransitionObservers(on player: AVPlayer) {
        installPeriodicObserver(on: player)
        installBoundaryObserver(on: player)
    }

    private func installPeriodicObserver(on player: AVPlayer) {
        removePeriodicObserver()
        periodicOwner = player
        periodicToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 4),
            queue: .main
        ) { [weak self] _ in
            self?.overlapTick()
        }
    }

    private func removePeriodicObserver() {
        if let periodicToken, let periodicOwner {
            periodicOwner.removeTimeObserver(periodicToken)
        }
        periodicToken = nil
        periodicOwner = nil
    }

    private func installBoundaryObserver(on player: AVPlayer) {
        removeBoundaryObserver()
        guard pendingOverlap > 0, let item = currentItem else { return }
        let itemDuration = item.duration.isNumeric ? CMTimeGetSeconds(item.duration) : 0
        let trackDuration = metadataDuration > 0 ? metadataDuration : itemDuration
        guard trackDuration > 0 else { return }
        let boundary = max(0, trackDuration - pendingOverlap)
        let boundaryTime = CMTime(seconds: boundary, preferredTimescale: 600)
        overlapBoundaryOwner = player
        overlapBoundaryToken = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: boundaryTime)],
            queue: .main
        ) { [weak self] in
            self?.overlapTick()
        }
        let current = player.currentTime().isNumeric ? CMTimeGetSeconds(player.currentTime()) : 0
        if current >= boundary {
            overlapTick()
        }
    }

    private func removeBoundaryObserver() {
        if let overlapBoundaryToken, let overlapBoundaryOwner {
            overlapBoundaryOwner.removeTimeObserver(overlapBoundaryToken)
        }
        overlapBoundaryToken = nil
        overlapBoundaryOwner = nil
    }

    private func removeTransitionObservers() {
        removePeriodicObserver()
        removeBoundaryObserver()
    }

    func setTrackDuration(_ seconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        metadataDuration = seconds
        if pendingOverlap > 0, currentItem != nil {
            installBoundaryObserver(on: activePlayer)
        }
    }

    private func overlapTick() {
        lock.lock()
        defer { lock.unlock() }
        guard !isOverlapping, !overlapAwaitingStandbyPlayback, pendingOverlap > 0,
              standbyPreparationState == .ready,
              let preloadedItem, preloadedItem.status == .readyToPlay,
              activePlayer.timeControlStatus == .playing,
              let item = currentItem else { return }
        let itemDuration = item.duration.isNumeric ? CMTimeGetSeconds(item.duration) : 0
        let trackDuration = metadataDuration > 0 ? metadataDuration : itemDuration
        guard trackDuration > 0 else { return }
        let remaining = trackDuration - CMTimeGetSeconds(activePlayer.currentTime())
        guard remaining > 0, remaining <= pendingOverlap else { return }
        requestOverlap()
    }

    /// Requests playback at zero gain. The ramp itself does not start until AVPlayer reports that
    /// the standby deck is genuinely rendering, preventing the outgoing deck from fading into a
    /// buffering incoming stream.
    private func requestOverlap() {
        overlapAwaitingStandbyPlayback = true
        rampStandby = 0
        applyDeckVolumes()
        standbyPlayer.play()
        startOverlapRampIfPossible()
    }

    private func startOverlapRampIfPossible() {
        guard overlapAwaitingStandbyPlayback,
              !isOverlapping,
              standbyPlayer.timeControlStatus == .playing,
              let item = currentItem else { return }
        let itemDuration = item.duration.isNumeric ? CMTimeGetSeconds(item.duration) : 0
        let trackDuration = metadataDuration > 0 ? metadataDuration : itemDuration
        let activePosition = activePlayer.currentTime().isNumeric
            ? CMTimeGetSeconds(activePlayer.currentTime())
            : 0
        let remaining = trackDuration - activePosition
        guard remaining > 0 else { return }

        overlapAwaitingStandbyPlayback = false
        isOverlapping = true
        overlapDuration = min(pendingOverlap, remaining)
        overlapStartedAt = Date()
        Logger.player.info(
            "[CROSSFADE] overlap started duration=\(self.overlapDuration, format: .fixed(precision: 2))s"
        )
        let timer = DispatchSource.makeTimerSource(queue: rampQueue)
        timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            self?.overlapRampTick()
        }
        overlapTimer = timer
        timer.resume()
    }

    private func overlapRampTick() {
        var endedTransition: AudioEngineTrackEnd?
        lock.lock()
        defer {
            lock.unlock()
            if let endedTransition {
                delegate?.audioEngineDidReachEndOfTrack(endedTransition)
            }
        }
        guard isOverlapping, overlapTimer != nil else { return }
        guard standbyPlayer.timeControlStatus == .playing else {
            rampActive = 1
            rampStandby = 0
            applyDeckVolumes()
            return
        }
        let standbyTime = standbyPlayer.currentTime()
        let standbyPosition = standbyTime.isNumeric ? CMTimeGetSeconds(standbyTime) : preloadedStartPosition
        let audibleProgress = max(0, standbyPosition - preloadedStartPosition)
        let progress = overlapDuration > 0 ? min(1, audibleProgress / overlapDuration) : 1
        let levels = Self.equalPowerLevels(progress: progress)
        rampActive = levels.outgoing
        rampStandby = levels.incoming
        applyDeckVolumes()
        if progress >= 1 {
            Logger.player.info("[CROSSFADE] overlap completed")
            overlapTimer?.cancel()
            overlapTimer = nil
            // Commit at the end of the blend; the outgoing item’s estimated EOF can arrive later.
            endedTransition = finalizeAdvance()
        }
    }

    nonisolated static func equalPowerLevels(progress: Double) -> (outgoing: Float, incoming: Float) {
        let x = Float(min(1, max(0, progress)))
        return (cos(x * .pi / 2), sin(x * .pi / 2))
    }

    /// Aborts a blend in progress (pause, seek, engine reset): the incoming deck rewinds and stays
    /// preloaded, the active deck returns to full level. The window re-arms via the periodic tick.
    private func cancelOverlap() {
        overlapTimer?.cancel()
        overlapTimer = nil
        let shouldReprepareStandby = isOverlapping || overlapAwaitingStandbyPlayback
        if shouldReprepareStandby {
            isOverlapping = false
            overlapAwaitingStandbyPlayback = false
            overlapStartedAt = nil
            overlapDuration = 0
            standbyPlayer.pause()
            if let item = preloadedItem {
                standbyPreparationState = .preparing
                item.seek(
                    to: CMTime(seconds: preloadedStartPosition, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero
                ) { [weak self, weak item] completed in
                    guard let self, let item else { return }
                    self.lock.lock()
                    defer { self.lock.unlock() }
                    guard completed, item === self.preloadedItem else { return }
                    self.prerollStandby(item)
                }
            }
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

    /// Handles a missing EOF notification only when playback is intended, the clock has
    /// stopped for the grace period, and the position is within the end-of-file tolerance.
    private func watchdogTick() {
        var endedTransition: AudioEngineTrackEnd?
        lock.lock()
        defer {
            lock.unlock()
            if let endedTransition {
                delegate?.audioEngineDidReachEndOfTrack(endedTransition)
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
        endedTransition = finalizeAdvance()
    }

    /// Promotes standby before notifying PlayerService; the subsequent play call adopts that deck.
    @discardableResult
    private func finalizeAdvance() -> AudioEngineTrackEnd? {
        // The notification, the crossfade ramp and the watchdog all land here, and any two of them can
        // fire for the same track — one advance per item.
        guard !didSignalEnd, let endedPlaybackToken = currentPlaybackToken else { return nil }
        // EOF and currentItem KVO can arrive in either order. Adopt only once AVQueuePlayer
        // has actually advanced; calling advanceToNextItem here could skip a second song.
        if preloadedInActiveQueue, activePlayer.currentItem === currentItem { return nil }
        let endedTime = currentItem?.currentTime() ?? .invalid
        let endedPosition = endedTime.isNumeric ? max(0, CMTimeGetSeconds(endedTime)) : 0
        didSignalEnd = true
        if preloadedInActiveQueue,
           let item = preloadedItem, activePlayer.currentItem === item,
           let trackID = preloadedTrackID, let token = preloadedPlaybackToken,
           let url = preloadedSourceURL {
            let time = item.currentTime()
            let promoted = AudioEnginePromotedPlayback(
                playbackToken: token, trackID: trackID, sourceURL: url,
                sourceHeaders: preloadedSourceHeaders, startedAt: Date(),
                position: time.isNumeric ? max(0, CMTimeGetSeconds(time)) : 0, audibleDuration: 0
            )
            handedOffTrackID = trackID
            promoteQueuedItem()
            return AudioEngineTrackEnd(endedPlaybackToken: endedPlaybackToken,
                                      endedPosition: endedPosition, promotedPlayback: promoted)
        }
        guard standbyPreparationState == .ready,
              let preloadedItem, preloadedItem.status == .readyToPlay,
              let trackID = preloadedTrackID,
              let promotedPlaybackToken = preloadedPlaybackToken,
              let sourceURL = preloadedSourceURL else {
            clearPreloadedDeck()
            return AudioEngineTrackEnd(
                endedPlaybackToken: endedPlaybackToken,
                endedPosition: endedPosition,
                promotedPlayback: nil
            )
        }
        let wasOverlapping = isOverlapping
        let incomingTime = standbyPlayer.currentTime()
        let incomingPosition = incomingTime.isNumeric
            ? max(preloadedStartPosition, CMTimeGetSeconds(incomingTime))
            : preloadedStartPosition
        let promotedPlayback = AudioEnginePromotedPlayback(
            playbackToken: promotedPlaybackToken,
            trackID: trackID,
            sourceURL: sourceURL,
            sourceHeaders: preloadedSourceHeaders,
            startedAt: overlapStartedAt ?? Date(),
            position: incomingPosition,
            audibleDuration: wasOverlapping ? max(0, incomingPosition - preloadedStartPosition) : 0
        )
        handedOffTrackID = trackID
        promotePreloaded(startPlaying: !wasOverlapping)
        return AudioEngineTrackEnd(
            endedPlaybackToken: endedPlaybackToken,
            endedPosition: endedPosition,
            promotedPlayback: promotedPlayback
        )
    }

    private func promotePreloaded(startPlaying: Bool) {
        overlapTimer?.cancel()
        overlapTimer = nil
        isOverlapping = false
        overlapAwaitingStandbyPlayback = false
        overlapDuration = 0
        overlapStartedAt = nil
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
        preloadedSourceURL = nil
        preloadedSourceHeaders = [:]
        preloadedStartPosition = 0
        standbyPreparationState = .idle
        pendingOverlap = 0
        metadataDuration = 0
        activePlayer.actionAtItemEnd = .pause
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
        removeTransitionObservers()
    }

    private func resetDecks(preservingActiveItem: Bool = false) {
        changingQueue = true
        defer { changingQueue = false }
        if preloadedInActiveQueue, let item = preloadedItem, item !== activePlayer.currentItem {
            activePlayer.remove(item)
        }
        preloadedInActiveQueue = false
        removeTransitionObservers()
        overlapTimer?.cancel()
        overlapTimer = nil
        isOverlapping = false
        overlapAwaitingStandbyPlayback = false
        overlapDuration = 0
        overlapStartedAt = nil
        shouldBePlaying = false
        didSignalEnd = false
        stopWatchdog()
        clearItemObservers()
        standbyStatusObserver?.invalidate()
        standbyStatusObserver = nil
        deckA.actionAtItemEnd = .pause
        deckB.actionAtItemEnd = .pause
        deckA.pause()
        deckB.pause()
        deckA.cancelPendingPrerolls()
        deckB.cancelPendingPrerolls()
        if !preservingActiveItem || !activeIsA { deckA.removeAllItems() }
        if !preservingActiveItem || activeIsA { deckB.removeAllItems() }
        currentItem = nil
        currentAsset = nil
        currentTrackID = nil
        currentPlaybackToken = nil
        preloadedItem = nil
        preloadedAsset = nil
        preloadedTrackID = nil
        preloadedPlaybackToken = nil
        preloadedSourceURL = nil
        preloadedSourceHeaders = [:]
        preloadedStartPosition = 0
        standbyPreparationState = .idle
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
        activePlayer.actionAtItemEnd = .pause
        if preloadedInActiveQueue, let item = preloadedItem, item !== activePlayer.currentItem {
            activePlayer.remove(item)
        }
        preloadedInActiveQueue = false
        removeTransitionObservers()
        standbyStatusObserver?.invalidate()
        standbyStatusObserver = nil
        standbyPlayer.pause()
        standbyPlayer.cancelPendingPrerolls()
        standbyPlayer.replaceCurrentItem(with: nil)
        standbyContext.tapInstalled = false
        preloadedItem = nil
        preloadedAsset = nil
        preloadedTrackID = nil
        preloadedPlaybackToken = nil
        preloadedSourceURL = nil
        preloadedSourceHeaders = [:]
        preloadedStartPosition = 0
        standbyPreparationState = .idle
        overlapAwaitingStandbyPlayback = false
        overlapDuration = 0
        overlapStartedAt = nil
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
        statusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard let self, item.status == .failed else { return }
            let failure = Self.failure(item: item, error: item.error)
            let playbackToken = self.lock.withLock {
                item === self.currentItem ? self.currentPlaybackToken : nil
            }
            guard let playbackToken else { return }
            self.delegate?.audioEngineDidError(failure, playbackToken: playbackToken)
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            guard let self else { return }
            self.lock.lock()
            // A queued EOF from the retired deck must not advance the newly promoted track.
            let endedTransition: AudioEngineTrackEnd? = if let item, item === self.currentItem {
                self.finalizeAdvance()
            } else {
                nil
            }
            self.lock.unlock()
            if let endedTransition {
                self.delegate?.audioEngineDidReachEndOfTrack(endedTransition)
            }
        }
        failObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self, weak item] note in
            guard let self else { return }
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            let failure = Self.failure(item: item, error: error)
            let playbackToken: AudioEnginePlaybackToken? = self.lock.withLock {
                guard let item, item === self.currentItem else { return nil }
                return self.currentPlaybackToken
            }
            guard let playbackToken else { return }
            self.delegate?.audioEngineDidError(failure, playbackToken: playbackToken)
        }
    }

    private static func failure(item: AVPlayerItem?, error: (any Error)?) -> AudioEngineFailure {
        let logCode = item?.errorLog()?.events.last.map {
            AudioEngineFailure.Code(domain: $0.errorDomain, value: $0.errorStatusCode)
        }
        return AudioEngineFailure(error: error, logCode: logCode)
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
