import Foundation
import Synchronization
import Testing
@testable import Minidisc

nonisolated final class StreamingDriverStub: StreamingAudioDriver, @unchecked Sendable {
    private struct Storage {
        var callback: (@Sendable (StreamingDriverEvent) -> Void)?
        var state: AudioEngineState = .stopped
        var position: Double = 0
        var duration: Double = 10
        var frames = 0
        var volume: Float = 1
        var muted = false
        var gain: Float = 0
        var queues = 0
        var stopped = false
        var sought: Double?
        var progresses = false
    }
    private let storage = Mutex(Storage())
    let entry = UUID()
    let renderSeek: Bool
    let sendsStartEvent: Bool
    init(renderSeek: Bool = true, sendsStartEvent: Bool = true) {
        self.renderSeek = renderSeek
        self.sendsStartEvent = sendsStartEvent
    }
    var onEvent: (@Sendable (StreamingDriverEvent) -> Void)? {
        get { storage.withLock { $0.callback } }
        set { storage.withLock { $0.callback = newValue } }
    }
    var state: AudioEngineState { storage.withLock { $0.state } }
    var position: Double {
        storage.withLock {
            if $0.progresses && $0.state == .playing {
                $0.position += 0.025
                $0.frames += 1_103
            }
            return $0.position
        }
    }
    var duration: Double {
        get { storage.withLock { $0.duration } }
        set { storage.withLock { $0.duration = newValue } }
    }
    var renderedFrames: Int { storage.withLock { $0.frames } }
    var isSeekable: Bool { true }
    var volume: Float {
        get { storage.withLock { $0.volume } }
        set { storage.withLock { $0.volume = newValue } }
    }
    var muted: Bool {
        get { storage.withLock { $0.muted } }
        set { storage.withLock { $0.muted = newValue } }
    }
    var queuedCount: Int { storage.withLock { $0.queues } }
    var gainValue: Float { storage.withLock { $0.gain } }
    var wasStopped: Bool { storage.withLock { $0.stopped } }
    var requestedSeek: Double? { storage.withLock { $0.sought } }
    func applyGain(dB: Float) { storage.withLock { $0.gain = dB } }
    func play(url: URL, headers: [String: String]) {
        storage.withLock { $0.state = .playing }
        if sendsStartEvent { onEvent?(.started(entry)) }
        onEvent?(.state(.playing))
    }
    func queue(url: URL, headers: [String: String]) { storage.withLock { $0.queues += 1 } }
    func pause() { storage.withLock { $0.state = .paused } }
    func resume() { storage.withLock { $0.state = .playing } }
    func stop() { storage.withLock { $0.stopped = true; $0.state = .stopped } }
    func seek(to seconds: Double) {
        storage.withLock {
            $0.sought = seconds
            $0.position = seconds
            $0.frames = renderSeek ? 0 : 88_200 // old frames + synthetic target are not success
            $0.progresses = renderSeek
        }
    }
    func setPosition(_ value: Double, progresses: Bool = false) {
        storage.withLock { $0.position = value; $0.progresses = progresses }
    }
    func finish(startingNext: Bool = false) {
        let callback = onEvent
        if startingNext { setPosition(0.02) }
        callback?(.finished(entry, natural: true, position: 10))
        if startingNext { callback?(.started(UUID())) }
    }
}

nonisolated final class StreamingDriverFactory: Sendable {
    private let storage = Mutex<[StreamingDriverStub]>([])
    let renderSeek: Bool
    init(renderSeek: Bool = true) { self.renderSeek = renderSeek }
    func make() -> any StreamingAudioDriver {
        let driver = StreamingDriverStub(renderSeek: renderSeek)
        storage.withLock { $0.append(driver) }
        return driver
    }
    var drivers: [StreamingDriverStub] { storage.withLock { $0 } }
}

nonisolated final class StreamingEngineObserver: AudioEngineDelegate, Sendable {
    private struct Storage {
        var ends: [AudioEngineTrackEnd] = []
        var errors: [AudioEnginePlaybackToken] = []
        var states: [(AudioEngineState, AudioEnginePlaybackToken)] = []
    }
    private let storage = Mutex(Storage())
    var ends: [AudioEngineTrackEnd] { storage.withLock { $0.ends } }
    var errors: [AudioEnginePlaybackToken] { storage.withLock { $0.errors } }
    var states: [(AudioEngineState, AudioEnginePlaybackToken)] { storage.withLock { $0.states } }
    func audioEngineDidChangeState(_ state: AudioEngineState, playbackToken: AudioEnginePlaybackToken) {
        storage.withLock { $0.states.append((state, playbackToken)) }
    }
    func audioEngineDidReachEndOfTrack(_ transition: AudioEngineTrackEnd) {
        storage.withLock { $0.ends.append(transition) }
    }
    func audioEngineDidError(_ failure: AudioEngineFailure, playbackToken: AudioEnginePlaybackToken) {
        storage.withLock { $0.errors.append(playbackToken) }
    }
}

@Suite("AudioStreaming engine — transport invariants")
struct AudioStreamingEngineTests {
    private let url = URL(fileURLWithPath: "/tmp/audio-streaming-test.wav")

    @Test func immediatePlaybackDoesNotEndWithAStaleBufferingEvent() {
        let factory = StreamingDriverFactory()
        let engine = AudioStreamingEngine(driverFactory: { factory.make() })
        let observer = StreamingEngineObserver()
        engine.delegate = observer
        let token = engine.play(trackID: "one", url: url, headers: [:])
        defer { engine.stop() }
        #expect(observer.states.first?.0 == .buffering)
        #expect(observer.states.last?.0 == .playing)
        #expect(observer.states.last?.1 == token)
    }

    @Test func parsedDurationIsAvailableBeforeTheStartCallback() {
        let driver = StreamingDriverStub(sendsStartEvent: false)
        driver.duration = 120.25
        let engine = AudioStreamingEngine(driverFactory: { driver })
        engine.play(trackID: "song", url: url, headers: [:])
        engine.setTrackDuration(123)
        defer { engine.stop() }
        #expect(engine.duration == 120.25)
    }

    @Test func parsedDurationReplacesEitherCatalogEstimateAndSurvivesTemporaryUnavailability() {
        let factory = StreamingDriverFactory()
        let engine = AudioStreamingEngine(driverFactory: { factory.make() })
        engine.play(trackID: "one", url: url, headers: [:])
        defer { engine.stop() }
        let driver = factory.drivers[0]
        driver.duration = 0
        engine.setTrackDuration(122)
        #expect(engine.duration == 122)
        driver.duration = 120.25
        #expect(engine.duration == 120.25)
        engine.setTrackDuration(118)
        #expect(engine.duration == 120.25)
        driver.duration = 0
        #expect(engine.duration == 120.25)
    }

    @Test func renderedPositionNeverBecomesTheTotalDuration() {
        let factory = StreamingDriverFactory()
        let engine = AudioStreamingEngine(driverFactory: { factory.make() })
        engine.play(trackID: "one", url: url, headers: [:])
        defer { engine.stop() }
        #expect(engine.duration == 10)
        factory.drivers[0].setPosition(10.7)
        factory.drivers[0].duration = 10.7 // AudioStreaming max(estimate, progress).
        #expect(engine.duration == 10)
        engine.play(trackID: "two", url: url, headers: [:])
        factory.drivers[1].duration = 7
        engine.setTrackDuration(7)
        #expect(engine.duration == 7) // No previous-track duration survives a new load.
    }

    @Test func freshLoadsAndResetRejectOldCallbacks() {
        let factory = StreamingDriverFactory()
        let engine = AudioStreamingEngine(driverFactory: { factory.make() })
        let observer = StreamingEngineObserver()
        engine.delegate = observer
        engine.volume = 0.3
        engine.applyReplayGain(dB: 4)
        let first = engine.play(trackID: "same", url: url, headers: [:])
        let old = factory.drivers[0]
        let lateCallback = old.onEvent
        engine.resetAfterMediaServicesReset()
        let second = engine.play(trackID: "same", url: url, headers: [:])
        defer { engine.stop() }
        lateCallback?(.finished(old.entry, natural: true, position: 10))
        lateCallback?(.failed(AudioEngineFailure(error: URLError(.timedOut))))
        #expect(second.rawValue > first.rawValue)
        #expect(old.wasStopped)
        #expect(factory.drivers[1].volume == 0.3)
        #expect(factory.drivers[1].gainValue == 4)
        #expect(observer.ends.isEmpty)
        #expect(observer.errors.isEmpty)
    }

    @Test func nativeQueuePromotesDuplicateSongWithoutReopening() throws {
        let factory = StreamingDriverFactory()
        let engine = AudioStreamingEngine(driverFactory: { factory.make() })
        let observer = StreamingEngineObserver()
        engine.delegate = observer
        let first = engine.play(trackID: "same", url: url, headers: ["X-Test": "value"])
        defer { engine.stop() }
        engine.preloadNext(trackID: "same", url: url, headers: ["X-Test": "value"],
                           crossfadeDuration: 0, replayGainDB: 3)
        factory.drivers[0].finish(startingNext: true)
        let transition = try #require(observer.ends.first)
        let promoted = try #require(transition.promotedPlayback)
        #expect(transition.endedPlaybackToken == first)
        #expect(promoted.playbackToken != first)
        #expect(promoted.sourceHeaders == ["X-Test": "value"])
        #expect(engine.play(trackID: "same", url: url, headers: [:]) == promoted.playbackToken)
        #expect(observer.states.last?.0 == .playing)
        #expect(observer.states.last?.1 == promoted.playbackToken)
        #expect(factory.drivers.count == 1)
        #expect(factory.drivers[0].gainValue == 3)
        #expect(observer.ends.count == 1)
    }

    @Test func manualNextDoesNotInheritTheQueuedReadersPositionOrLateEvents() throws {
        let factory = StreamingDriverFactory()
        let engine = AudioStreamingEngine(driverFactory: { factory.make() })
        let observer = StreamingEngineObserver()
        engine.delegate = observer
        let first = engine.play(trackID: "one", url: url, headers: [:])
        defer { engine.stop() }
        let old = factory.drivers[0]
        old.duration = 187.153
        old.setPosition(180)
        #expect(engine.duration == 187.153)
        engine.preloadNext(trackID: "two", url: url, headers: [:], crossfadeDuration: 0, replayGainDB: 3)
        let lateCallback = old.onEvent
        let next = engine.play(trackID: "two", url: url, headers: [:])
        #expect(next != first)
        #expect(engine.progress == 0)
        #expect(engine.duration == 10)
        #expect(old.wasStopped)
        lateCallback?(.started(UUID()))
        lateCallback?(.finished(old.entry, natural: true, position: 187.153))
        #expect(observer.ends.isEmpty)
        #expect(observer.states.last?.1 == next)
    }

    @Test func airPlayUsesNativeQueueDespiteCrossfadeSetting() {
        let factory = StreamingDriverFactory()
        let engine = AudioStreamingEngine(driverFactory: { factory.make() })
        engine.setAirPlayActive(true)
        engine.play(trackID: "one", url: url, headers: [:])
        defer { engine.stop() }
        engine.preloadNext(trackID: "two", url: url, headers: [:], crossfadeDuration: 2, replayGainDB: 0)
        #expect(factory.drivers[0].queuedCount == 1)
        #expect(factory.drivers.count == 1)
    }

    @Test func changingGainOrCrossfadeKeepsDecodedQueueAndAppliesGainAtHandoff() throws {
        let factory = StreamingDriverFactory()
        let engine = AudioStreamingEngine(driverFactory: { factory.make() })
        let observer = StreamingEngineObserver()
        engine.delegate = observer
        engine.play(trackID: "one", url: url, headers: [:])
        defer { engine.stop() }
        engine.preloadNext(trackID: "two", url: url, headers: [:], crossfadeDuration: 0, replayGainDB: -2)
        engine.preloadNext(trackID: "two", url: url, headers: [:], crossfadeDuration: 2, replayGainDB: 3)
        let driver = factory.drivers[0]
        #expect(factory.drivers.count == 1)
        #expect(driver.queuedCount == 1)
        #expect(driver.gainValue == 0)
        driver.finish(startingNext: true)
        #expect(try #require(observer.ends.first?.promotedPlayback).trackID == "two")
        #expect(driver.gainValue == 3)
    }

    @Test func airPlayConvertsAnAudibleCrossfadeWithoutReopeningCurrentReader() async throws {
        let factory = StreamingDriverFactory()
        let engine = AudioStreamingEngine(driverFactory: { factory.make() })
        let observer = StreamingEngineObserver()
        engine.delegate = observer
        engine.play(trackID: "one", url: url, headers: [:])
        defer { engine.stop() }
        factory.drivers[0].setPosition(8.5)
        engine.preloadNext(trackID: "two", url: url, headers: [:], crossfadeDuration: 2, replayGainDB: 0)
        try await waitUntil { factory.drivers.count == 2 }
        let current = factory.drivers[0]
        let incoming = factory.drivers[1]
        incoming.setPosition(0.2, progresses: true)
        try await waitUntil { incoming.volume > 0 }
        engine.setAirPlayActive(true)
        #expect(!current.wasStopped)
        #expect(current.volume == 1)
        #expect(current.queuedCount == 1)
        #expect(incoming.wasStopped)
        engine.setAirPlayActive(false)
        current.finish(startingNext: true)
        let promoted = try #require(observer.ends.first?.promotedPlayback)
        #expect(promoted.trackID == "two")
        #expect(promoted.audibleDuration == 0)
        #expect(factory.drivers.count == 2)
    }

    @Test(arguments: [false, true])
    func nextEntryStartingBeforePreviousFinishPreservesBothIdentities(paused: Bool) throws {
        let factory = StreamingDriverFactory()
        let engine = AudioStreamingEngine(driverFactory: { factory.make() })
        let observer = StreamingEngineObserver()
        engine.delegate = observer
        let first = engine.play(trackID: "one", url: url, headers: [:])
        defer { engine.stop() }
        engine.preloadNext(trackID: "two", url: url, headers: [:], crossfadeDuration: 0, replayGainDB: 0)
        if paused { engine.pause() }
        let driver = factory.drivers[0]
        let nextEntry = UUID()
        driver.setPosition(0.1)
        driver.onEvent?(.started(nextEntry))
        #expect(observer.ends.isEmpty)
        driver.onEvent?(.finished(driver.entry, natural: true, position: 10))
        if paused {
            #expect(observer.ends.isEmpty)
            engine.resume()
        }
        let transition = try #require(observer.ends.first)
        let promoted = try #require(transition.promotedPlayback)
        #expect(transition.endedPlaybackToken == first)
        #expect(promoted.trackID == "two")
        #expect(engine.play(trackID: "two", url: url, headers: [:]) == promoted.playbackToken)
        #expect(factory.drivers.count == 1)
        driver.onEvent?(.finished(nextEntry, natural: true, position: 10))
        #expect(observer.ends.count == 2)
        #expect(observer.ends.last?.endedPlaybackToken == promoted.playbackToken)
        #expect(observer.ends.last?.promotedPlayback == nil)
    }

    @Test(arguments: [false, true])
    func pauseRacingWithNativePromotionDoesNotSkipTheNextEntry(manualNext: Bool) throws {
        let factory = StreamingDriverFactory()
        let engine = AudioStreamingEngine(driverFactory: { factory.make() })
        let observer = StreamingEngineObserver()
        engine.delegate = observer
        let first = engine.play(trackID: "one", url: url, headers: [:])
        defer { engine.stop() }
        engine.preloadNext(trackID: "two", url: url, headers: [:], crossfadeDuration: 0, replayGainDB: 0)
        engine.pause()
        factory.drivers[0].finish(startingNext: true)
        #expect(observer.ends.isEmpty)
        if manualNext {
            #expect(engine.play(trackID: "two", url: url, headers: [:]) != first)
        } else {
            engine.resume()
            let promoted = try #require(observer.ends.first?.promotedPlayback)
            #expect(promoted.trackID == "two")
            #expect(promoted.playbackToken != first)
        }
        #expect(engine.progress < 0.5)
        #expect(factory.drivers[0].state == .playing)
        #expect(observer.states.last?.0 == .playing)
        #expect(observer.states.last?.1 != first)
        #expect(factory.drivers.count == 1)
    }

    @Test func syntheticSeekPositionDoesNotCountAsRenderedAudio() async {
        let factory = StreamingDriverFactory(renderSeek: false)
        let engine = AudioStreamingEngine(seekTimeout: .milliseconds(150), driverFactory: { factory.make() })
        let observer = StreamingEngineObserver()
        engine.delegate = observer
        let token = engine.play(trackID: "one", url: url, headers: [:])
        defer { engine.stop() }
        #expect(await engine.seek(to: 3) == false)
        #expect(factory.drivers[0].muted)
        #expect(factory.drivers[0].state == .paused)
        #expect(observer.errors == [token])
    }

    @Test func confirmedSeekPreservesPauseAndUserVolume() async {
        let factory = StreamingDriverFactory()
        let engine = AudioStreamingEngine(driverFactory: { factory.make() })
        engine.volume = 0.4
        engine.play(trackID: "one", url: url, headers: [:])
        defer { engine.stop() }
        engine.pause()
        #expect(await engine.seek(to: 3))
        #expect(factory.drivers[0].state == .paused)
        #expect(!factory.drivers[0].muted)
        #expect(factory.drivers[0].volume == 0.4)
        #expect(engine.progress >= 3 && engine.progress < 3.5)
    }

    @Test func replacingItemCancelsSeekWithoutUnmutingReplacement() async throws {
        let factory = StreamingDriverFactory(renderSeek: false)
        let engine = AudioStreamingEngine(driverFactory: { factory.make() })
        engine.play(trackID: "one", url: url, headers: [:])
        defer { engine.stop() }
        let task = Task { await engine.seek(to: 3) }
        try await waitUntil { factory.drivers[0].requestedSeek != nil }
        engine.volume = 0
        engine.play(trackID: "two", url: url, headers: [:])
        #expect(await task.value == false)
        #expect(factory.drivers[1].volume == 0)
        #expect(!factory.drivers[1].wasStopped)
    }

    @Test func cancellingDecodedQueueRestoresCurrentPositionAndPause() async throws {
        let factory = StreamingDriverFactory()
        let engine = AudioStreamingEngine(driverFactory: { factory.make() })
        let observer = StreamingEngineObserver()
        engine.delegate = observer
        engine.play(trackID: "one", url: url, headers: [:])
        defer { engine.stop() }
        factory.drivers[0].setPosition(2)
        engine.preloadNext(trackID: "two", url: url, headers: [:], crossfadeDuration: 0, replayGainDB: 0)
        engine.cancelPreload()
        engine.pause()
        #expect(factory.drivers.count == 2)
        try await waitUntil { !factory.drivers[1].muted }
        #expect(factory.drivers[0].wasStopped)
        #expect(factory.drivers[1].state == .paused)
        #expect(engine.progress >= 2 && engine.progress < 2.5)
        #expect(observer.ends.isEmpty)
    }

    @Test(arguments: [false, true])
    func crossfadeUsesTwoDecksAndReportsAlreadyHeardAudio(manualNext: Bool) async throws {
        let factory = StreamingDriverFactory()
        let engine = AudioStreamingEngine(driverFactory: { factory.make() })
        let observer = StreamingEngineObserver()
        engine.delegate = observer
        engine.play(trackID: "one", url: url, headers: [:])
        engine.setTrackDuration(10)
        defer { engine.stop() }
        factory.drivers[0].setPosition(8.5)
        engine.preloadNext(trackID: "two", url: url, headers: [:], crossfadeDuration: 2, replayGainDB: 5)
        try await waitUntil { factory.drivers.count == 2 }
        factory.drivers[1].setPosition(0.2, progresses: true)
        try await waitUntil { factory.drivers[1].volume > 0 }
        #expect(factory.drivers[0].volume < 1)
        #expect(factory.drivers[1].gainValue == 5)
        if manualNext {
            let token = engine.play(trackID: "two", url: url, headers: [:])
            #expect(observer.states.last?.0 == .playing)
            #expect(observer.states.last?.1 == token)
            #expect(factory.drivers[0].wasStopped)
            return
        }
        factory.drivers[0].finish()
        let promoted = try #require(observer.ends.first?.promotedPlayback)
        #expect(promoted.trackID == "two")
        #expect(promoted.audibleDuration > 0)
        #expect(factory.drivers[0].wasStopped)
        #expect(engine.play(trackID: "two", url: url, headers: [:]) == promoted.playbackToken)
        #expect(observer.states.last?.0 == .playing)
        #expect(observer.states.last?.1 == promoted.playbackToken)
    }

    @Test func pauseDuringCrossfadeRetainsTheUpcomingSongForResume() async throws {
        let factory = StreamingDriverFactory()
        let engine = AudioStreamingEngine(driverFactory: { factory.make() })
        engine.play(trackID: "one", url: url, headers: [:])
        engine.setTrackDuration(10)
        defer { engine.stop() }
        factory.drivers[0].setPosition(8.5)
        engine.preloadNext(trackID: "two", url: url, headers: [:], crossfadeDuration: 2, replayGainDB: 0)
        try await waitUntil { factory.drivers.count == 2 }
        engine.pause()
        #expect(factory.drivers[1].wasStopped)
        #expect(factory.drivers[0].volume == 1)
        engine.resume()
        try await waitUntil { factory.drivers.count == 3 }
        #expect(factory.drivers[2].volume == 0)
        #expect(!factory.drivers[2].wasStopped)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !predicate(), clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(predicate())
    }
}
