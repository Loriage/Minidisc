// Minidisc — Music client for Subsonic/OpenSubsonic servers
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

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
/// on other threads; a recursive lock guards the deck roles and transition state. ReplayGain is
/// applied per deck by an `MTAudioProcessingTap` (Sound-Check style, never the visible volume).
nonisolated final class AVPlayerEngine: AudioEngine, @unchecked Sendable {
    weak var delegate: AudioEngineDelegate?

    private let lock = NSRecursiveLock()

    private let deckA = AVPlayer()
    private let deckB = AVPlayer()
    private let contextA = ReplayGainTapContext()
    private let contextB = ReplayGainTapContext()
    private var activeIsA = true
    private var activePlayer: AVPlayer { activeIsA ? deckA : deckB }
    private var standbyPlayer: AVPlayer { activeIsA ? deckB : deckA }
    private var activeContext: ReplayGainTapContext { activeIsA ? contextA : contextB }
    private var standbyContext: ReplayGainTapContext { activeIsA ? contextB : contextA }

    private var currentItem: AVPlayerItem?
    private var preloadedItem: AVPlayerItem?
    private var preloadedTrackID: String?
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
                self.lock.unlock()
                guard isActive else { return }
                switch player.timeControlStatus {
                case .playing:                       self.delegate?.audioEngineDidChangeState(.playing)
                case .paused:                        self.delegate?.audioEngineDidChangeState(.paused)
                case .waitingToPlayAtSpecifiedRate:  self.delegate?.audioEngineDidChangeState(.buffering)
                @unknown default:                    break
                }
            })
        }
    }

    deinit {
        overlapTimer?.cancel()
        watchdogTimer?.cancel()
        clearItemObservers()
        standbyStatusObserver?.invalidate()
        timeControlObservers.forEach { $0.invalidate() }
        if let periodicToken, let periodicOwner {
            periodicOwner.removeTimeObserver(periodicToken)
        }
    }

    // MARK: - AudioEngine

    func play(trackID: String, url: URL, headers: [String: String]) {
        lock.lock()
        defer { lock.unlock() }

        // Adopt a hand-off the engine already performed at the natural end of the previous track.
        if trackID == handedOffTrackID, currentItem != nil {
            handedOffTrackID = nil
            beginPlaying()
            return
        }

        // Manual skip into the preloaded track: promote the warm standby deck right away.
        if trackID == preloadedTrackID, preloadedItem?.status == .readyToPlay {
            promotePreloaded(startPlaying: true)
            return
        }

        // Fresh start — drop both decks.
        resetDecks()
        let options: [String: Any]? = headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers]
        let asset = AVURLAsset(url: url, options: options)
        let item = AVPlayerItem(asset: asset)
        attachItemObservers(item)
        currentItem = item
        activePlayer.replaceCurrentItem(with: item)
        beginPlaying()
        installReplayGainTap(on: item, asset: asset, context: activeContext, trackID: trackID)
        installPeriodicObserver(on: activePlayer)
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
        let options: [String: Any]? = headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers]
        let asset = AVURLAsset(url: url, options: options)
        let item = AVPlayerItem(asset: asset)
        // The incoming deck must carry its own normalization throughout the overlap. Applying it only
        // after PlayerService confirms the hand-off creates an audible volume step halfway through.
        standbyContext.gain = pow(10, replayGainDB / 20)
        installReplayGainTap(on: item, asset: asset, context: standbyContext, trackID: trackID)
        standbyPlayer.replaceCurrentItem(with: item)
        preloadedItem = item
        preloadedTrackID = trackID
        pendingOverlap = crossfadeDuration
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
            // A small tolerance is inaudible for music and lets AVPlayer land on a nearby packet boundary.
            // Exact zero-tolerance seeks are unnecessarily slow on compressed progressive streams.
            let tolerance = CMTime(seconds: 0.05, preferredTimescale: 600)
            player.seek(
                to: CMTime(seconds: seconds, preferredTimescale: 600),
                toleranceBefore: tolerance,
                toleranceAfter: tolerance
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
        lock.lock()
        defer { lock.unlock() }
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
            finalizeAdvance()
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
        lock.lock()
        defer { lock.unlock() }
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
        finalizeAdvance()
    }

    /// The current item played to its end. With a preloaded next: retire the finished deck, promote
    /// the standby (already blending in a crossfade, or started now for gapless), then tell
    /// PlayerService — whose confirming `play` adopts the promoted deck via `handedOffTrackID`.
    private func finalizeAdvance() {
        // The notification, the crossfade ramp and the watchdog all land here, and any two of them can
        // fire for the same track — one advance per item.
        guard !didSignalEnd else { return }
        didSignalEnd = true
        guard let preloadedItem, preloadedItem.status == .readyToPlay,
              let trackID = preloadedTrackID else {
            clearPreloadedDeck()
            delegate?.audioEngineDidReachEndOfTrack()
            return
        }
        let wasOverlapping = isOverlapping
        handedOffTrackID = trackID
        promotePreloaded(startPlaying: !wasOverlapping)
        delegate?.audioEngineDidReachEndOfTrack()
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
        activeIsA.toggle()
        currentItem = preloadedItem
        preloadedItem = nil
        preloadedTrackID = nil
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
        preloadedItem = nil
        preloadedTrackID = nil
        handedOffTrackID = nil
        pendingOverlap = 0
        metadataDuration = 0
        rampActive = 1
        rampStandby = 1
        applyDeckVolumes()
    }

    /// Clears only the standby role. Caller holds `lock`.
    private func clearPreloadedDeck() {
        standbyStatusObserver?.invalidate()
        standbyStatusObserver = nil
        standbyPlayer.pause()
        standbyPlayer.replaceCurrentItem(with: nil)
        preloadedItem = nil
        preloadedTrackID = nil
        pendingOverlap = 0
    }

    private func applyDeckVolumes() {
        activePlayer.volume = fadeLevel * rampActive
        standbyPlayer.volume = fadeLevel * rampStandby
    }

    // MARK: - Per-item observers

    private func attachItemObservers(_ item: AVPlayerItem) {
        clearItemObservers()
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self, item.status == .failed else { return }
            self.delegate?.audioEngineDidError(item.error?.localizedDescription ?? "AVPlayer item failed")
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
            if let item, item === self.currentItem {
                self.finalizeAdvance()
            }
            self.lock.unlock()
        }
        // A mid-stream network failure (connection drop, server hiccup) — surface it so PlayerService
        // can route to its error handling (radio failover, or a retry/timeout state).
        failObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] note in
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            self?.delegate?.audioEngineDidError(error?.localizedDescription ?? "Playback failed")
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

    private func installReplayGainTap(
        on item: AVPlayerItem,
        asset: AVURLAsset,
        context: ReplayGainTapContext,
        trackID: String
    ) {
        Task { @MainActor in
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first else {
                Logger.player.warning("[REPLAYGAIN] no audio track available for '\(trackID, privacy: .public)'")
                return
            }
            guard let tap = Self.makeReplayGainTap(context: context) else {
                Logger.player.warning("[REPLAYGAIN] audio tap creation failed for '\(trackID, privacy: .public)'")
                return
            }
            let params = AVMutableAudioMixInputParameters(track: track)
            params.audioTapProcessor = tap
            let mix = AVMutableAudioMix()
            mix.inputParameters = [params]
            item.audioMix = mix
            Logger.player.info("[REPLAYGAIN] audio tap installed for '\(trackID, privacy: .public)'")
        }
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

    var gain: Float {
        get { Float(bitPattern: gainBits.load(ordering: .relaxed)) }
        set { gainBits.store(newValue.bitPattern, ordering: .relaxed) }
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
