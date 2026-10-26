import Foundation

/// Owns AudioStreaming's native sequential queue and an independent incoming crossfade deck.
/// PlayerService remains authoritative for transport intent, the logical queue and system recovery.
nonisolated final class AudioStreamingEngine: AudioEngine, @unchecked Sendable {
    private final class Item {
        let token: AudioEnginePlaybackToken
        let trackID: String
        let url: URL
        let headers: [String: String]
        var gain: Float
        var entryID: UUID?
        var startedAt: Date?
        var audibleDuration: Double = 0
        var measuredDuration: Double = 0

        init(token: AudioEnginePlaybackToken, trackID: String, url: URL,
             headers: [String: String], gain: Float) {
            self.token = token; self.trackID = trackID; self.url = url
            self.headers = headers; self.gain = gain
        }
    }

    private final class Deck {
        let id = UUID()
        let driver: any StreamingAudioDriver
        var item: Item
        var lastPosition: Double = 0
        var ended = false
        var pendingEnd: Double?

        init(driver: any StreamingAudioDriver, item: Item) {
            self.driver = driver; self.item = item
        }
    }

    private final class Preparation {
        let item: Item
        var overlap: Double
        var queued = false
        var deck: Deck?
        var rampDuration: Double?
        var lastIncomingPosition: Double = 0

        init(item: Item, overlap: Double) { self.item = item; self.overlap = overlap }
    }

    private let lock = NSRecursiveLock()
    private let factory: @Sendable () -> any StreamingAudioDriver
    private let diagnostics: PlaybackDiagnostics?
    private weak var storedDelegate: (any AudioEngineDelegate)?
    private var active: Deck?
    private var preparation: Preparation?
    private var handoffToken: AudioEnginePlaybackToken?
    private var nextToken: UInt64 = 0
    private var shouldPlay = false
    private var airPlay = false
    private var userVolume: Float = 1
    private var gainDB: Float = 0
    private var metadataDuration: Double = 0
    private var seekGeneration: UInt64 = 0
    private var seeking = false
    private var restoring = false
    private var restorationTask: Task<Void, Never>?
    private var timer: DispatchSourceTimer?
    private var lastDiagnosticTime: TimeInterval = 0
    private var health = PlaybackDiagnosticHealth()
    private let seekTimeout: Duration

    init(diagnostics: PlaybackDiagnostics? = nil, seekTimeout: Duration = .seconds(8),
         driverFactory: @escaping @Sendable () -> any StreamingAudioDriver = { AudioStreamingDriver() }) {
        self.diagnostics = diagnostics
        self.factory = driverFactory
        self.seekTimeout = seekTimeout
    }

    deinit {
        restorationTask?.cancel()
        timer?.cancel()
        active?.driver.onEvent = nil
        active?.driver.stop()
        preparation?.deck?.driver.onEvent = nil
        preparation?.deck?.driver.stop()
    }

    var delegate: (any AudioEngineDelegate)? {
        get { lock.withLock { storedDelegate } }
        set { lock.withLock { storedDelegate = newValue } }
    }

    @discardableResult
    func play(trackID: String, url: URL, headers: [String: String]) -> AudioEnginePlaybackToken {
        lock.withLock {
            if let active, handoffToken == active.item.token, active.item.trackID == trackID {
                handoffToken = nil
                shouldPlay = true
                active.driver.resume()
                // Native queue/crossfade playback may already be running. The service has
                // just adopted this token and cannot rely on another native state change.
                reportCurrentPlaybackState(active)
                startTimer()
                return active.item.token
            }
            invalidateSeek()
            shouldPlay = true
            handoffToken = nil
            metadataDuration = 0
            if let prepared = preparation, prepared.item.trackID == trackID, let active {
                preparation = nil
                if let incoming = prepared.deck {
                    dispose(active)
                    self.active = incoming
                    incoming.driver.volume = userVolume
                    incoming.driver.resume()
                } else if prepared.queued, active.pendingEnd != nil, prepared.item.entryID != nil {
                    // EOF already moved the native queue while we were paused. Adopt that
                    // confirmed entry without restarting it or skipping another song.
                    active.item = prepared.item
                    active.ended = false
                    active.pendingEnd = nil
                    active.lastPosition = finite(active.driver.position)
                    active.driver.applyGain(dB: prepared.item.gain)
                    active.driver.resume()
                } else {
                    // In 1.4.5, playNextInQueue only advances entries still in `upcoming`;
                    // a decoded entry makes it a no-op. Manual Next must reopen its source
                    // on a fresh reader so the old clock, duration and callbacks cannot leak.
                    dispose(active)
                    self.active = makeDeck(prepared.item, volume: userVolume)
                    self.active?.driver.play(url: prepared.item.url, headers: prepared.item.headers)
                }
                if let active = self.active {
                    if active.item.entryID != nil { reportCurrentPlaybackState(active) }
                    else { report(.buffering, deck: active) }
                }
                startTimer()
                return prepared.item.token
            }
            discardPreparation(reloadNativeQueue: false)
            if let active { dispose(active) }
            let item = makeItem(trackID: trackID, url: url, headers: headers, gain: gainDB)
            let deck = makeDeck(item, volume: userVolume)
            active = deck
            report(.buffering, deck: deck)
            deck.driver.play(url: url, headers: headers)
            startTimer()
            return item.token
        }
    }

    func pause() {
        lock.withLock {
            shouldPlay = false
            // A seek may run silently to completion; it must preserve the newer Pause intent.
            if !seeking { active?.driver.pause() }
            if let preparation, preparation.deck != nil {
                discardPreparation(reloadNativeQueue: false)
                preparation.item.entryID = nil
                preparation.item.startedAt = nil
                preparation.item.audibleDuration = 0
                self.preparation = Preparation(item: preparation.item, overlap: preparation.overlap)
            }
            timer?.cancel()
            timer = nil
            health.reset()
            if let active { report(.paused, deck: active) }
        }
    }

    func resume() {
        lock.withLock {
            guard let active, !active.ended else { return }
            shouldPlay = true
            if let position = active.pendingEnd {
                active.pendingEnd = nil
                finish(active, position: position)
                if let incoming = self.active, !incoming.ended {
                    incoming.driver.resume()
                    reportCurrentPlaybackState(incoming)
                }
                startTimer()
                return
            }
            if !seeking {
                active.driver.resume()
                if !restoring, active.driver.state == .playing { report(.playing, deck: active) }
            }
            startTimer()
        }
    }

    func stop() {
        lock.withLock {
            shouldPlay = false
            invalidateSeek()
            discardPreparation(reloadNativeQueue: false)
            if let active { dispose(active) }
            active = nil
            handoffToken = nil
            metadataDuration = 0
            health.reset()
            timer?.cancel()
            timer = nil
        }
    }

    func resetAfterMediaServicesReset() {
        // Every physical AudioPlayer and EQ node is discarded. User volume and tokens survive.
        stop()
    }

    var volume: Float {
        get { lock.withLock { userVolume } }
        set {
            lock.withLock {
                userVolume = newValue.isFinite ? min(1, max(0, newValue)) : 0
                applyVolumes()
            }
        }
    }
    var progress: Double {
        lock.withLock {
            guard let active else { return 0 }
            if let end = active.pendingEnd { return end }
            if restoring || seeking || active.ended { return active.lastPosition }
            return finite(active.driver.position)
        }
    }
    var duration: Double {
        lock.withLock {
            guard let active else { return 0 }
            // Catalogue durations are rounded to seconds and can differ from the selected
            // encoded file. Once parsed, use its duration for the scrubber and the crossfade.
            // AudioStreaming returns max(estimatedDuration, progress), including a synthetic
            // seek target: never turn that moving playhead into a new total duration.
            // Parsing can finish before the asynchronous didStartPlaying callback.
            if !seeking && !restoring, !active.ended, active.pendingEnd == nil {
                let parsed = finite(active.driver.duration)
                let position = finite(active.driver.position)
                if parsed > 0, parsed > position + 0.05 {
                    active.item.measuredDuration = parsed
                }
            }
            return active.item.measuredDuration > 0 ? active.item.measuredDuration : metadataDuration
        }
    }
    var isSeekable: Bool { lock.withLock { active?.driver.isSeekable == true } }
    var isReady: Bool { lock.withLock { active == nil } }
    // RemoteAudioSource already reconnects after a path failure. Cancelling a decoded queue
    // would instead rebuild the active reader and discard otherwise playable PCM buffers.
    var preservesPreloadOnNetworkChange: Bool { true }
    var preservesPreloadOnAirPlayChange: Bool { true }

    func applyReplayGain(dB: Float) {
        lock.withLock {
            gainDB = dB.isFinite ? dB : 0
            active?.item.gain = gainDB
            active?.driver.applyGain(dB: gainDB)
        }
    }

    func setTrackDuration(_ seconds: Double) {
        lock.withLock { metadataDuration = finite(seconds) }
    }

    func preloadNext(trackID: String, url: URL, headers: [String: String],
                     crossfadeDuration: Double, replayGainDB: Float) {
        lock.withLock {
            guard active != nil else { return }
            let overlap = airPlay ? 0 : finite(crossfadeDuration)
            if let preparation, preparation.item.trackID == trackID,
               preparation.item.url == url, preparation.item.headers == headers,
               preparation.queued || (preparation.overlap == 0) == (overlap == 0) {
                // Once sequential audio is queued, switching it to a crossfade would require
                // restarting the current reader. Apply that mode to the next unprepared pair.
                if !preparation.queued { preparation.overlap = overlap }
                preparation.item.gain = replayGainDB
                preparation.deck?.driver.applyGain(dB: replayGainDB)
                return
            }
            discardPreparation(reloadNativeQueue: true)
            preparation = Preparation(item: makeItem(trackID: trackID, url: url, headers: headers,
                                                    gain: replayGainDB), overlap: overlap)
            submitNativeQueueIfReady()
        }
    }

    func cancelPreload() { lock.withLock { discardPreparation(reloadNativeQueue: true) } }

    func setAirPlayActive(_ active: Bool) {
        lock.withLock {
            guard airPlay != active else { return }
            airPlay = active
            if active, let preparation, preparation.overlap > 0 {
                let item = preparation.item
                discardPreparation(reloadNativeQueue: false)
                item.entryID = nil
                item.startedAt = nil
                item.audibleDuration = 0
                self.preparation = Preparation(item: item, overlap: 0)
                submitNativeQueueIfReady()
            }
        }
    }

    /// AudioStreaming reports the requested target before rendering it. Require two advancing
    /// observations of decoded frames at the target while muted, never just `progress == target`.
    func seek(to seconds: Double) async -> Bool {
        guard seconds.isFinite, seconds >= 0 else { return false }
        let request: (deck: Deck, generation: UInt64)? = lock.withLock {
            guard let active else { return nil }
            if active.item.entryID != nil, active.driver.duration > 0, !active.driver.isSeekable {
                return nil
            }
            let pending = preparation
            discardPreparation(reloadNativeQueue: false) // flushQueueOnSeek removes native entries.
            if let pending {
                pending.item.entryID = nil
                pending.item.startedAt = nil
                pending.item.audibleDuration = 0
                preparation = Preparation(item: pending.item, overlap: pending.overlap)
            }
            seekGeneration &+= 1
            seeking = true
            active.driver.muted = true
            active.ended = false
            if active.pendingEnd != nil {
                active.pendingEnd = nil
                active.item.entryID = nil
                active.driver.play(url: active.item.url, headers: active.item.headers)
            }
            return (active, seekGeneration)
        }
        guard let request else { return false }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: seekTimeout)
        var issued = false
        var issuedDuration = 0.0
        var previous: (position: Double, frames: Int)?
        var succeeded = false
        while !Task.isCancelled, clock.now < deadline {
            let observation: (Double, Int, Double?)? = lock.withLock {
                guard active === request.deck, seekGeneration == request.generation,
                      request.deck.driver.state != .error else { return nil }
                let driver = request.deck.driver
                // A just-created AudioPlayer reports seekable before it has an entry. Wait for
                // didStart and a parsed duration, including seeks during cold restoration.
                if !issued, request.deck.item.entryID != nil, driver.isSeekable {
                    issuedDuration = driver.duration
                    driver.resume()
                    driver.seek(to: seconds)
                    issued = true
                }
                guard issued else { return (seconds, 0, nil) }
                return (driver.position, driver.renderedFrames, request.deck.pendingEnd)
            }
            guard let (position, frames, end) = observation else { break }
            // At EOF there cannot be two more render observations. The entry-specific natural
            // end event is authoritative, but only for a request at that entry's known end.
            if let end, issuedDuration > 0, seconds >= issuedDuration - 0.05, abs(end - seconds) < 1 {
                succeeded = true
                break
            }
            // A pending request returns exactly `seconds`; an old frame counter paired with
            // that synthetic position must never unmute a failed or unprocessed seek.
            if position.isFinite, abs(position - seconds) < 1,
               abs(position - seconds) > 0.000_001, frames > 0 {
                if let previous, frames > previous.frames, position > previous.position {
                    succeeded = true
                    break
                }
                previous = (position, frames)
            } else { previous = nil }
            do { try await Task.sleep(for: .milliseconds(15)) } catch { break }
        }
        return lock.withLock {
            guard active === request.deck, seekGeneration == request.generation else { return false }
            seeking = false
            let driver = request.deck.driver
            if succeeded && !Task.isCancelled {
                request.deck.lastPosition = request.deck.pendingEnd ?? finite(driver.position)
                if !shouldPlay { driver.pause() }
                driver.muted = false
                applyVolumes()
                health.reset()
                if let end = request.deck.pendingEnd {
                    if shouldPlay && !restoring {
                        request.deck.pendingEnd = nil
                        finish(request.deck, position: end)
                    }
                } else {
                    submitNativeQueueIfReady()
                }
                return true
            }
            // Preserve the prior position and silence on failure; PlayerService owns retry.
            driver.pause()
            if !Task.isCancelled && !restoring {
                storedDelegate?.audioEngineDidError(AudioEngineFailure(error: URLError(.timedOut)),
                                                   playbackToken: request.deck.item.token)
            }
            return false
        }
    }

    private func invalidateSeek() {
        restorationTask?.cancel()
        restorationTask = nil
        seekGeneration &+= 1
        seeking = false
        restoring = false
    }

    private func makeItem(trackID: String, url: URL, headers: [String: String], gain: Float) -> Item {
        nextToken &+= 1
        return Item(token: .init(rawValue: nextToken), trackID: trackID, url: url, headers: headers, gain: gain)
    }

    private func makeDeck(_ item: Item, volume: Float) -> Deck {
        let deck = Deck(driver: factory(), item: item)
        let id = deck.id
        deck.driver.volume = volume
        deck.driver.applyGain(dB: item.gain)
        deck.driver.onEvent = { [weak self] event in self?.receive(event, from: id) }
        return deck
    }

    private func dispose(_ deck: Deck) {
        deck.driver.onEvent = nil
        deck.driver.stop()
    }

    private func submitNativeQueueIfReady() {
        guard let active, active.item.entryID != nil, !seeking, !restoring,
              !active.ended, active.pendingEnd == nil,
              let preparation, preparation.overlap == 0, !preparation.queued else { return }
        preparation.queued = true
        active.driver.queue(url: preparation.item.url, headers: preparation.item.headers)
    }

    private func discardPreparation(reloadNativeQueue: Bool) {
        guard let preparation else { return }
        self.preparation = nil
        if let deck = preparation.deck { dispose(deck) }
        active?.driver.volume = userVolume
        guard reloadNativeQueue, preparation.queued, let old = active, !old.ended else { return }

        // 1.4.5's removeFromQueue only removes entries still in `upcoming`, not already-decoded
        // entries. Recreate at the confirmed position rather than risk playing a cancelled song.
        // This can briefly buffer when editing an already-preloaded queue.
        let position = finite(old.driver.position)
        invalidateSeek()
        dispose(old)
        old.item.entryID = nil
        let replacement = makeDeck(old.item, volume: userVolume)
        replacement.lastPosition = position
        replacement.driver.muted = true
        active = replacement
        restoring = true
        replacement.driver.play(url: replacement.item.url, headers: replacement.item.headers)
        report(.buffering, deck: replacement)
        restorationTask = Task { [weak self] in
            guard let self else { return }
            let success = await self.seek(to: position)
            self.lock.withLock {
                guard self.active === replacement else { return }
                self.restoring = false
                self.restorationTask = nil
                if success {
                    if let end = replacement.pendingEnd {
                        if self.shouldPlay {
                            replacement.pendingEnd = nil
                            self.finish(replacement, position: end)
                        }
                        return
                    }
                    self.submitNativeQueueIfReady()
                    if self.shouldPlay { self.startTimer() }
                    self.report(self.shouldPlay ? .playing : .paused, deck: replacement)
                } else if !Task.isCancelled {
                    self.storedDelegate?.audioEngineDidError(
                        AudioEngineFailure(error: URLError(.cannotDecodeContentData)),
                        playbackToken: replacement.item.token
                    )
                }
            }
        }
    }

    private func receive(_ event: StreamingDriverEvent, from deckID: UUID) {
        lock.withLock {
            guard let deck = active?.id == deckID ? active : preparation?.deck,
                  deck.id == deckID else { return }
            let isActive = deck === active
            switch event {
            case .started(let id):
                // A late-decoded next entry can start before the outgoing finish callback.
                // Keep the outgoing identity until its EOF is handled, including during Pause.
                if isActive, let preparation, preparation.queued,
                   deck.pendingEnd != nil || (deck.item.entryID != nil && deck.item.entryID != id) {
                    preparation.item.entryID = id
                    if !shouldPlay { deck.driver.pause() }
                    return
                }
                deck.item.entryID = id
                if isActive {
                    if !shouldPlay && !seeking && !restoring { deck.driver.pause() }
                    if shouldPlay && !seeking && !restoring { reportCurrentPlaybackState(deck) }
                    submitNativeQueueIfReady()
                }
            case .state(let state):
                guard isActive, !seeking, !restoring else { return }
                if !shouldPlay, state == .playing || state == .buffering {
                    deck.driver.pause()
                    return
                }
                // EOF is handled with its item-specific finish event, not a state callback.
                if state != .stopped && state != .error { report(state, deck: deck) }
            case .failed(let error):
                if isActive {
                    storedDelegate?.audioEngineDidError(error, playbackToken: deck.item.token)
                } else {
                    discardPreparation(reloadNativeQueue: false)
                }
            case .finished(let id, let natural, let position):
                guard natural, isActive, !deck.ended,
                      id == deck.item.entryID else { return }
                if seeking || restoring || !shouldPlay {
                    deck.pendingEnd = finite(position)
                    return
                }
                finish(deck, position: position)
            }
        }
    }

    private func finish(_ outgoing: Deck, position: Double) {
        let ended = outgoing.item.token
        outgoing.pendingEnd = nil
        outgoing.ended = true
        outgoing.lastPosition = finite(position)
        let promoted: AudioEnginePromotedPlayback?
        if shouldPlay, let preparation, preparation.queued || preparation.deck != nil {
            self.preparation = nil
            let incoming: Deck
            if let deck = preparation.deck {
                incoming = deck
                dispose(outgoing)
            } else {
                incoming = outgoing
                incoming.item = preparation.item
            }
            incoming.ended = false
            active = incoming
            incoming.driver.volume = userVolume
            incoming.driver.applyGain(dB: incoming.item.gain)
            let currentPosition = finite(incoming.driver.position)
            incoming.lastPosition = currentPosition
            metadataDuration = 0
            handoffToken = incoming.item.token
            promoted = AudioEnginePromotedPlayback(
                playbackToken: incoming.item.token, trackID: incoming.item.trackID,
                sourceURL: incoming.item.url, sourceHeaders: incoming.item.headers,
                startedAt: incoming.item.startedAt ?? Date(), position: currentPosition,
                audibleDuration: incoming.item.audibleDuration
            )
        } else {
            promoted = nil
        }
        storedDelegate?.audioEngineDidReachEndOfTrack(.init(
            endedPlaybackToken: ended, endedPosition: finite(position), promotedPlayback: promoted
        ))
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "minidisc.audiostreaming.monitor"))
        timer.schedule(deadline: .now(), repeating: .milliseconds(30), leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    private func tick() {
        lock.withLock {
            guard let active else { return }
            if !seeking && !restoring && !active.ended {
                active.lastPosition = finite(active.driver.position)
            }
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastDiagnosticTime >= 1 {
                lastDiagnosticTime = now
                diagnostics?.record(.streamingEngineSnapshot(.init(
                    token: active.item.token, state: active.driver.state,
                    position: active.lastPosition, duration: duration,
                    renderedFrames: active.driver.renderedFrames, intended: shouldPlay,
                    seeking: seeking || restoring, queued: preparation?.queued == true,
                    overlapping: preparation?.deck != nil, airPlay: airPlay
                )))
                if let (finding, elapsed) = health.observe(token: active.item.token,
                    position: active.lastPosition, intended: shouldPlay && !seeking && !restoring,
                    waitingAtBoundary: active.ended, at: now) {
                    diagnostics?.record(.health(active.item.token, finding, seconds: elapsed))
                }
            }
            guard shouldPlay, !seeking, !restoring, !active.ended,
                  let preparation, preparation.overlap > 0, !airPlay else { return }
            let remaining = duration - active.lastPosition
            guard duration > 2 * preparation.overlap, remaining > 0 else { return }
            if preparation.deck == nil, remaining <= preparation.overlap {
                let incoming = makeDeck(preparation.item, volume: 0)
                preparation.deck = incoming
                incoming.driver.play(url: incoming.item.url, headers: incoming.item.headers)
            }
            guard let incoming = preparation.deck else { return }
            let position = finite(incoming.driver.position)
            guard incoming.driver.state == .playing, position > preparation.lastIncomingPosition else {
                active.driver.volume = userVolume
                incoming.driver.volume = 0
                return
            }
            if preparation.rampDuration == nil {
                preparation.rampDuration = min(preparation.overlap, remaining)
                incoming.item.startedAt = Date()
            }
            let delta = position - preparation.lastIncomingPosition
            if delta < 1 { incoming.item.audibleDuration += delta }
            preparation.lastIncomingPosition = position
            applyVolumes()
        }
    }

    private func applyVolumes() {
        guard let active else { return }
        guard let preparation, let incoming = preparation.deck,
              let rampDuration = preparation.rampDuration, rampDuration > 0 else {
            active.driver.volume = userVolume
            return
        }
        let fraction = min(1, max(0, incoming.item.audibleDuration / rampDuration))
        active.driver.volume = userVolume * Float(cos(fraction * .pi / 2))
        incoming.driver.volume = userVolume * Float(sin(fraction * .pi / 2))
    }

    private func reportCurrentPlaybackState(_ deck: Deck) {
        report(deck.driver.state == .playing ? .playing : .buffering, deck: deck)
    }

    private func report(_ state: AudioEngineState, deck: Deck) {
        storedDelegate?.audioEngineDidChangeState(state, playbackToken: deck.item.token)
    }

    private func finite(_ value: Double) -> Double { value.isFinite ? max(0, value) : 0 }
}
