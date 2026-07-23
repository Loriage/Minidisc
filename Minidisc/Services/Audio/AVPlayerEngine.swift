// Minidisc — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Accelerate
import AVFoundation
import Foundation
import MediaToolbox

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

    var supportsOverlappedCrossfade: Bool { true }

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
    private var preloadedURL: URL?
    /// Overlap window for the pending transition (0 = gapless butt-splice).
    private var pendingOverlap: Double = 0
    /// URL of an item the engine already promoted at a hand-off; the next `play` with it adopts.
    private var handedOffURL: URL?

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
        clearItemObservers()
        standbyStatusObserver?.invalidate()
        timeControlObservers.forEach { $0.invalidate() }
        if let periodicToken, let periodicOwner {
            periodicOwner.removeTimeObserver(periodicToken)
        }
    }

    // MARK: - AudioEngine

    func play(url: URL, headers: [String: String]) {
        lock.lock()
        defer { lock.unlock() }

        // Adopt a hand-off the engine already performed at the natural end of the previous track.
        if url == handedOffURL, currentItem != nil {
            handedOffURL = nil
            activePlayer.play()
            return
        }

        // Manual skip into the preloaded track: promote the warm standby deck right away.
        if url == preloadedURL, preloadedItem != nil {
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
        activePlayer.play()
        installReplayGainTap(on: item, asset: asset, context: activeContext)
        installPeriodicObserver(on: activePlayer)
    }

    func preloadNext(url: URL, headers: [String: String], crossfadeDuration: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard currentItem != nil else { return }
        if url == preloadedURL {
            pendingOverlap = crossfadeDuration
            return
        }
        standbyStatusObserver?.invalidate()
        standbyStatusObserver = nil
        standbyPlayer.pause()
        let options: [String: Any]? = headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers]
        let asset = AVURLAsset(url: url, options: options)
        let item = AVPlayerItem(asset: asset)
        // Carry the current gain until the real value lands when PlayerService confirms the advance.
        standbyContext.gain = activeContext.gain
        installReplayGainTap(on: item, asset: asset, context: standbyContext)
        standbyPlayer.replaceCurrentItem(with: item)
        preloadedItem = item
        preloadedURL = url
        pendingOverlap = crossfadeDuration
        // Preroll once ready so the hand-off starts render-tight.
        standbyStatusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self, item.status == .readyToPlay else { return }
            self.lock.lock()
            if item === self.preloadedItem {
                self.standbyPlayer.preroll(atRate: 1) { _ in }
            }
            self.lock.unlock()
        }
    }

    func pause() {
        lock.lock()
        defer { lock.unlock() }
        cancelOverlap()
        activePlayer.pause()
    }

    func resume() {
        lock.lock()
        defer { lock.unlock() }
        activePlayer.play()
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        resetDecks()
    }

    func seek(to seconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        cancelOverlap()
        activePlayer.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
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
        return CMTimeGetSeconds(duration)
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
        guard !isOverlapping, pendingOverlap > 0, preloadedItem != nil,
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

    /// The current item played to its end. With a preloaded next: retire the finished deck, promote
    /// the standby (already blending in a crossfade, or started now for gapless), then tell
    /// PlayerService — whose confirming `play` adopts the promoted deck via `handedOffURL`.
    private func finalizeAdvance() {
        guard preloadedItem != nil, let url = preloadedURL else {
            delegate?.audioEngineDidReachEndOfTrack()
            return
        }
        let wasOverlapping = isOverlapping
        handedOffURL = url
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
        preloadedURL = nil
        pendingOverlap = 0
        metadataDuration = 0
        rampActive = 1
        rampStandby = 1
        applyDeckVolumes()
        if let item = currentItem {
            attachItemObservers(item)
        }
        if startPlaying {
            activePlayer.play()
        }
        installPeriodicObserver(on: activePlayer)
    }

    private func resetDecks() {
        overlapTimer?.cancel()
        overlapTimer = nil
        isOverlapping = false
        clearItemObservers()
        standbyStatusObserver?.invalidate()
        standbyStatusObserver = nil
        deckA.pause()
        deckB.pause()
        deckA.replaceCurrentItem(with: nil)
        deckB.replaceCurrentItem(with: nil)
        currentItem = nil
        preloadedItem = nil
        preloadedURL = nil
        handedOffURL = nil
        pendingOverlap = 0
        metadataDuration = 0
        rampActive = 1
        rampStandby = 1
        applyDeckVolumes()
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
        ) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.finalizeAdvance()
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

    private func installReplayGainTap(on item: AVPlayerItem, asset: AVURLAsset, context: ReplayGainTapContext) {
        Task { @MainActor in
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
                  let tap = Self.makeReplayGainTap(context: context) else { return }
            let params = AVMutableAudioMixInputParameters(track: track)
            params.audioTapProcessor = tap
            let mix = AVMutableAudioMix()
            mix.inputParameters = [params]
            item.audioMix = mix
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

/// Shared between the engine (writes on control paths) and the audio render thread (reads in the tap).
/// A bare Float is deliberate: aligned 32-bit loads/stores are atomic on ARM, and the render thread
/// must never take a lock.
private nonisolated final class ReplayGainTapContext: @unchecked Sendable {
    nonisolated(unsafe) var gain: Float = 1.0
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
