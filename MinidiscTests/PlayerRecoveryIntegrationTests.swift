import AVFoundation
import Foundation
import SwiftData
import SwiftSonic
import Synchronization
import Testing
@testable import Minidisc

private nonisolated final class RecoveryTestEngine: AudioEngine, Sendable {
    private struct Storage {
        var delegate: AudioEngineDelegate?
        var plays = 0
        var stops = 0
        var resets = 0
        var poisoned = false
        var active = false
        var volume: Float = 1
        var playingSince: Date?
        var position: Double = 0
    }
    private let storage = Mutex(Storage())
    var delegate: AudioEngineDelegate? {
        get { storage.withLock { $0.delegate } }
        set { storage.withLock { $0.delegate = newValue } }
    }
    var playCount: Int { storage.withLock { $0.plays } }
    var stopCount: Int { storage.withLock { $0.stops } }
    var resetCount: Int { storage.withLock { $0.resets } }
    func poisonMediaServices() { storage.withLock { $0.poisoned = true; $0.playingSince = nil } }
    var token: AudioEnginePlaybackToken { .init(rawValue: UInt64(playCount)) }
    func play(trackID: String, url: URL, headers: [String: String]) -> AudioEnginePlaybackToken {
        storage.withLock {
            $0.plays += 1
            $0.active = true
            $0.playingSince = nil
            $0.position = 0
        }
        let token = token
        delegate?.audioEngineDidChangeState(.paused, playbackToken: token)
        delegate?.audioEngineDidChangeState(.buffering, playbackToken: token)
        return token
    }
    func startAdvancing() { storage.withLock { if !$0.poisoned { $0.playingSince = Date() } } }
    func pause() { storage.withLock { $0.playingSince = nil } }
    func resume() {}
    func stop() { storage.withLock { $0.stops += 1; $0.active = false; $0.playingSince = nil } }
    func resetAfterMediaServicesReset() {
        storage.withLock {
            $0.resets += 1
            $0.poisoned = false
            $0.active = false
            $0.playingSince = nil
            $0.position = 0
        }
    }
    func seek(to seconds: Double) async -> Bool { storage.withLock { $0.position = seconds }; return true }
    var volume: Float {
        get { storage.withLock { $0.volume } }
        set { storage.withLock { $0.volume = newValue } }
    }
    var progress: Double {
        storage.withLock { $0.position + ($0.playingSince.map { Date().timeIntervalSince($0) } ?? 0) }
    }
    var duration: Double { 120 }
    var isSeekable: Bool { true }
    var isReady: Bool { storage.withLock { !$0.active } }
    func applyReplayGain(dB: Float) {}
    func cancelPreload() {}
    func setTrackEndTrim(_ seconds: Double) {}
    func setTrackDuration(_ seconds: Double) {}
    func preloadNext(trackID: String, url: URL, headers: [String: String], crossfadeDuration: Double, leadInTrim: Double, replayGainDB: Float) {}
}

private nonisolated final class RecoveryTestAudioSession: AudioSessionControlling {
    static let headphones = AudioRouteOutputSnapshot(uid: "headphones", portType: .bluetoothA2DP)
    static let speaker = AudioRouteOutputSnapshot(uid: "speaker", portType: .builtInSpeaker)
    private struct Storage {
        var outputs = [RecoveryTestAudioSession.headphones]
        var activations = 0
        var invalidations = 0
        var failuresRemaining = 0
    }
    private let storage = Mutex(Storage())
    var outputs: [AudioRouteOutputSnapshot] {
        get { storage.withLock { $0.outputs } }
        set { storage.withLock { $0.outputs = newValue } }
    }
    var activations: Int { storage.withLock { $0.activations } }
    var invalidations: Int { storage.withLock { $0.invalidations } }
    func failNextActivations(_ count: Int) { storage.withLock { $0.failuresRemaining = count } }
    func activate() throws {
        let shouldFail = storage.withLock {
            $0.activations += 1
            if $0.failuresRemaining > 0 { $0.failuresRemaining -= 1; return true }
            return false
        }
        if shouldFail { throw NSError(domain: NSOSStatusErrorDomain, code: -50) }
    }
    func deactivate() {}
    func invalidateConfiguration() { storage.withLock { $0.invalidations += 1 } }
}

private actor RecoveryTestResolver: MediaResolverProtocol {
    var missingIDs: Set<String> = []
    var blockAvailability = false
    var availabilityCalls = 0
    private var pending: CheckedContinuation<MediaAvailability, Never>?
    private var blockedResolutionID: String?
    private var pendingResolution: CheckedContinuation<Void, Never>?
    var isResolvingBlockedTrack: Bool { pendingResolution != nil }
    func blockResolution(of trackID: String) { blockedResolutionID = trackID }
    func releaseResolution() {
        blockedResolutionID = nil
        pendingResolution?.resume()
        pendingResolution = nil
    }
    func configure(missing: Set<String> = [], block: Bool = false) {
        missingIDs = missing
        blockAvailability = block
    }
    func resolve(songId: String, serverId: UUID) async throws -> MediaSource {
        if songId == blockedResolutionID {
            await withCheckedContinuation { pendingResolution = $0 }
        }
        return .stream(URL(string: "https://playback.invalid/stream")!, customHeaders: [:])
    }
    func resolveRadio(_ station: InternetRadioStation) async throws -> MediaSource { throw MinidiscError.notImplemented }
    func availability(songId: String, serverId: UUID) async -> MediaAvailability {
        availabilityCalls += 1
        if blockAvailability {
            return await withCheckedContinuation { pending = $0 }
        }
        return missingIDs.contains(songId) ? .missing : .unknown
    }
    func releaseAvailability(_ result: MediaAvailability) {
        blockAvailability = false
        pending?.resume(returning: result)
        pending = nil
    }
}

private nonisolated final class RecoveryTestLibrary: AlbumBrowsing, ArtistBrowsing, PlaybackQueueBuilding, PlaybackReporting {
    func album(id: String) async throws -> AlbumID3 { throw MinidiscError.notImplemented }
    func allAlbums() async throws -> [AlbumID3] { [] }
    func artists() async throws -> [ArtistIndex] { [] }
    func artist(id: String) async throws -> ArtistID3 { throw MinidiscError.notImplemented }
    func fetchAllTracks(forArtistID artistID: String) async throws -> [DisplayableSong] { [] }
    func smartShuffleQueue(targetSize: Int) async throws -> [DisplayableSong] { [] }
    func similarBackfillQueue(targetSize: Int, excludedIds: Set<String>) async throws -> [DisplayableSong] { [] }
    func instantMix(from seed: InstantMixSeed, count: Int) async throws -> [DisplayableSong] { [] }
    func scrobble(songId: String, submission: Bool) async {}
}

@MainActor
private struct RecoveryListenBrainzTransport: ListenBrainzTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw URLError(.unsupportedURL)
    }
}

@MainActor
private struct RecoveryHarness {
    let player: PlayerService
    let state = PlayerState()
    let engine = RecoveryTestEngine()
    let audioSession = RecoveryTestAudioSession()
    let resolver = RecoveryTestResolver()
    let diagnostics = PlaybackDiagnostics(capacity: 500)
    let defaults = UserDefaults(suiteName: "playback-recovery.\(UUID())")!

    init(
        startupGrace: Duration = .milliseconds(600),
        audioStartupGrace: Duration = .milliseconds(800),
        audioRetryDelay: Duration = .milliseconds(40)
    ) throws {
        let container = try ModelContainer.minidisc(inMemory: true)
        let server = MockServerService()
        server.state.activeServer = ServerSnapshot(from: ServerConfig(
            displayName: "Test", baseURL: "https://playback.invalid", username: "test"
        ))
        let toast = ToastService()
        let download = DownloadService(serverService: server, modelContainer: container, toastService: toast)
        let cacheSettings = CacheSettings(defaults: defaults)
        cacheSettings.cacheFormat = .flacOriginal // The stub server cannot create background cache URLs.
        let crossfade = CrossfadeSettings(defaults: defaults)
        player = PlayerService(
            state: state,
            mediaResolver: resolver,
            serverService: server,
            sessionService: PlaybackSessionService(modelContainer: try ModelContainer.session(inMemory: true)),
            artworkImageCache: ArtworkImageCache(
                coverArtURLProvider: { _, _ in nil },
                dataLoader: { _ in throw URLError(.unsupportedURL) },
                imageDecoder: { _, _ in nil }
            ),
            libraryService: RecoveryTestLibrary(),
            audioStreamCache: MockAudioStreamCache(),
            downloadService: download,
            cacheSettings: cacheSettings,
            playbackPreferences: PlaybackPreferences(defaults: defaults),
            replayGainSettings: ReplayGainSettings(defaults: defaults),
            crossfadeSettings: crossfade,
            initialCrossfadeConfig: crossfade.config,
            toastService: toast,
            statsService: StatsService(modelContainer: container),
            listenBrainzService: ListenBrainzService(
                client: ListenBrainzClient(transport: RecoveryListenBrainzTransport()),
                keychain: MockKeychain(), userDefaults: UserDefaults(suiteName: "playback-recovery-lb.\(UUID())")!,
                queueFileURL: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).json")
            ),
            playbackDiagnostics: diagnostics,
            engine: engine,
            networkRecoveryTiming: .init(
                startupGrace: startupGrace, stallGrace: .milliseconds(100),
                retryDelay: .milliseconds(40), validationDelay: .milliseconds(200)
            ),
            audioSession: audioSession,
            audioRecoveryTiming: .init(
                retryDelay: audioRetryDelay, routeGrace: .seconds(2),
                startupGrace: audioStartupGrace, pollInterval: .milliseconds(10)
            )
        )
    }

    func play(_ ids: [String] = ["a", "b"]) async throws {
        let tracks = try ids.map { id in
            DisplayableSong(from: try JSONDecoder().decode(Song.self, from: Data(
                "{\"id\":\"\(id)\",\"title\":\"Test\",\"isDir\":false,\"duration\":120}".utf8
            )))
        }
        try await player.play(tracks: tracks, startIndex: 0)
    }

    var report: String {
        diagnostics.makeReport(context: .init(
            appVersion: "test", appBuild: "0", operatingSystem: "test",
            playbackStatus: .init(state.playbackState), isPlaybackAvailable: true,
            networkPath: nil, connectionVersion: nil
        ))
    }

    func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(6)
        while !(await condition()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await condition(), "\(report)\nEngine plays=\(engine.playCount) position=\(engine.progress)")
    }
}

@Suite("Player recovery integration", .serialized)
@MainActor
struct PlayerRecoveryIntegrationTests {
    private var mediaReset: AudioEngineFailure {
        .init(error: NSError(domain: AVFoundationErrorDomain, code: AVError.Code.mediaServicesWereReset.rawValue))
    }

    private func confirmAudioResumed(_ h: RecoveryHarness) async throws {
        // A real player cannot become ready before its initial callbacks. Wait for both mock
        // startup events to reach the actor before sending the ready event through the test seam.
        try await h.waitUntil {
            let attempt = h.report.components(separatedBy: "audio-recovery attempt-started").last ?? ""
            return attempt.contains("engine state=paused") && attempt.contains("engine state=buffering")
        }
        h.engine.startAdvancing()
        await h.player.handleEngineState(.playing, playbackToken: h.engine.token)
        try await h.waitUntil { h.report.contains("audio-recovery progress-validated") }
    }

    @Test func mediaServicesFailureAutomaticallyRestoresAudioWithoutCheckingServerOrSkippingTracks() async throws {
        let h = try RecoveryHarness(startupGrace: .seconds(10))
        try await h.play(["a", "b", "c"])
        _ = await h.engine.seek(to: 37)
        h.state.position = 37
        let failedToken = h.engine.token
        h.engine.poisonMediaServices()
        await h.player.handleEngineError(mediaReset, playbackToken: failedToken)
        #expect(h.engine.resetCount == 1)
        #expect(h.audioSession.invalidations == 1)
        #expect(h.state.queue.map(\.id) == ["a", "b", "c"])
        #expect(h.state.currentTrack?.id == "a")
        #expect(h.state.wantsPlayback)
        #expect(h.state.position == 37)
        try await h.waitUntil { h.engine.playCount == 2 }
        await h.player.handleEngineState(.playing, playbackToken: h.engine.token)
        #expect(h.engine.progress == 37)
        #expect(h.engine.volume > 0)
        // The seek from zero and a transient playing event are not success.
        try await Task.sleep(for: .milliseconds(80))
        #expect(!h.report.contains("audio-recovery progress-validated"))
        try await confirmAudioResumed(h)
        #expect(await h.resolver.availabilityCalls == 0)
        #expect(!h.report.contains("item-rebuilt"))
        #expect(h.state.waitingReason == nil)

        // Callbacks from the discarded players cannot damage this or the following songs.
        await h.player.handleEngineError(mediaReset, playbackToken: failedToken)
        try await h.player.skipToNext()
        #expect(h.state.currentTrack?.id == "b")
        try await h.player.skipToNext()
        #expect(h.state.currentTrack?.id == "c")
        #expect(h.engine.playCount == 4)
        #expect(h.engine.resetCount == 1)
        await h.player.stop()
    }

    @Test func mediaServicesResetPreservesPausedPositionWithoutStartingAudio() async throws {
        let h = try RecoveryHarness(startupGrace: .seconds(10))
        try await h.play()
        _ = await h.engine.seek(to: 37)
        h.state.position = 37
        await h.player.pause()
        let activations = h.audioSession.activations
        let oldToken = h.engine.token
        await h.player.handleMediaServicesReset()
        try await Task.sleep(for: .milliseconds(120))
        #expect(h.engine.isReady)
        #expect(h.state.position == 37)
        #expect(h.state.playbackState == .paused)
        #expect(h.audioSession.activations == activations)
        await h.player.handleEngineState(.playing, playbackToken: oldToken)
        #expect(h.engine.playCount == 1)

        await h.player.resume()
        #expect(h.engine.playCount == 2)
        await h.player.handleEngineState(.playing, playbackToken: h.engine.token)
        #expect(h.engine.progress == 37)
        #expect(h.state.playbackState == .playing)
        await h.player.stop()
    }

    @Test func mediaServicesResetCancelsAnInFlightNetworkRecovery() async throws {
        let h = try RecoveryHarness()
        await h.resolver.configure(block: true)
        try await h.play()
        try await h.waitUntil { await h.resolver.availabilityCalls == 1 }
        await h.player.handleMediaServicesReset()
        await h.resolver.releaseAvailability(.available)
        try await h.waitUntil { h.engine.playCount == 2 }
        try await confirmAudioResumed(h)
        #expect(h.state.currentTrack?.id == "a")
        #expect(!h.report.contains("item-rebuilt"))
        #expect(await h.resolver.availabilityCalls == 1)
        await h.player.stop()
    }

    @Test func pauseCancelsRecoveryBeforeAnyAutomaticPlay() async throws {
        let h = try RecoveryHarness(audioRetryDelay: .milliseconds(200))
        try await h.play()
        await h.player.handleMediaServicesReset()
        await h.player.pause()
        try await Task.sleep(for: .milliseconds(300))
        #expect(h.engine.playCount == 1)
        #expect(h.state.playbackState == .paused)
        await h.player.stop()
    }

    @Test func nextSupersedesAudioRecoveryAndOldFailures() async throws {
        let h = try RecoveryHarness(audioRetryDelay: .milliseconds(200))
        try await h.play()
        let oldToken = h.engine.token
        await h.player.handleMediaServicesReset()
        try await h.player.skipToNext()
        await h.player.handleEngineError(mediaReset, playbackToken: oldToken)
        try await Task.sleep(for: .milliseconds(300))
        #expect(h.engine.playCount == 2)
        #expect(h.state.currentTrack?.id == "b")
        #expect(h.state.playbackState == .playing)
        #expect(h.engine.resetCount == 1)
        await h.player.stop()
    }

    @Test func globalResetDuringNextResolutionCannotRestartThePreviousTrack() async throws {
        let h = try RecoveryHarness(audioRetryDelay: .milliseconds(150))
        try await h.play()
        await h.player.handleMediaServicesReset()
        await h.resolver.blockResolution(of: "b")
        let next = Task { try await h.player.skipToNext() }
        try await h.waitUntil { await h.resolver.isResolvingBlockedTrack }
        await h.player.handleMediaServicesReset()
        try await Task.sleep(for: .milliseconds(200))
        #expect(h.engine.playCount == 1)
        await h.resolver.releaseResolution()
        try await next.value
        #expect(h.engine.playCount == 2)
        #expect(h.state.currentTrack?.id == "b")
        await h.player.stop()
    }

    @Test func recoveryWaitsForTheOriginalBluetoothOutput() async throws {
        let h = try RecoveryHarness()
        try await h.play()
        h.audioSession.outputs = [RecoveryTestAudioSession.speaker]
        await h.player.handleMediaServicesReset()
        try await h.waitUntil { h.report.contains("waiting-for-route") }
        #expect(h.engine.playCount == 1)
        h.audioSession.outputs = [.init(uid: "different-headphones", portType: .bluetoothA2DP)]
        await h.player.handleRouteChange(.newDeviceAvailable)
        try await Task.sleep(for: .milliseconds(80))
        #expect(h.engine.playCount == 1)
        h.audioSession.outputs = [RecoveryTestAudioSession.headphones]
        await h.player.handleRouteChange(.newDeviceAvailable)
        try await h.waitUntil { h.engine.playCount == 2 }
        try await confirmAudioResumed(h)
        await h.player.stop()
    }

    @Test func systemSuspensionBeforeResetStillRetainsPlayIntent() async throws {
        let h = try RecoveryHarness()
        try await h.play()
        h.audioSession.outputs = [RecoveryTestAudioSession.speaker]
        await h.player.handleRouteChange(
            .oldDeviceUnavailable, previousRouteOutputs: [RecoveryTestAudioSession.headphones]
        )
        #expect(h.state.playbackState == .paused)
        await h.player.handleAudioSessionInterruption(.began(routeDisconnected: true))
        let activations = h.audioSession.activations
        await h.player.handleMediaServicesReset()
        try await Task.sleep(for: .milliseconds(100))
        #expect(h.state.wantsPlayback)
        #expect(h.audioSession.activations == activations)
        #expect(h.engine.playCount == 1)
        h.audioSession.outputs = [RecoveryTestAudioSession.headphones]
        await h.player.handleAudioSessionInterruption(.ended(shouldResume: true))
        try await h.waitUntil { h.engine.playCount == 2 }
        try await confirmAudioResumed(h)
        await h.player.stop()
    }

    @Test func activationFailureRecoversAutomaticallyWithOneIncidentBudget() async throws {
        let h = try RecoveryHarness()
        try await h.play()
        h.audioSession.failNextActivations(1)
        await h.player.handleMediaServicesReset()
        try await h.waitUntil { h.report.contains("activation-failed") }
        await h.player.handleMediaServicesReset() // duplicate OS signal must retain the budget
        try await h.waitUntil { h.engine.playCount == 2 }
        #expect(h.report.contains("audio-recovery attempt-started number=2"))
        try await confirmAudioResumed(h)
        #expect(await h.resolver.availabilityCalls == 0)
        await h.player.stop()
    }

    @Test func repeatedResetFailuresExhaustOneBudgetWithoutSkippingOrProbingTheServer() async throws {
        let h = try RecoveryHarness()
        try await h.play()
        await h.player.handleMediaServicesReset()
        for count in 2...4 {
            try await h.waitUntil { h.engine.playCount == count }
            await h.player.handleEngineError(mediaReset, playbackToken: h.engine.token)
        }
        try await h.waitUntil { h.report.contains("audio-recovery exhausted") }
        #expect(h.engine.playCount == 4)
        #expect(h.state.currentTrack?.id == "a")
        #expect(await h.resolver.availabilityCalls == 0)
        #expect(!h.report.contains("retry-budget-exhausted"))
        guard case .error(.audioSystemUnavailable) = h.state.playbackState else {
            Issue.record("Persistent audio failure was not classified as an audio-system error")
            await h.player.stop()
            return
        }
        await h.player.stop()
    }

    @Test func stalledAudioRecoveryIsBoundedAndThirdAttemptCanSucceed() async throws {
        let h = try RecoveryHarness(audioStartupGrace: .milliseconds(600))
        try await h.play()
        await h.player.handleMediaServicesReset()
        try await h.waitUntil { h.engine.playCount == 4 }
        try await confirmAudioResumed(h)
        #expect(!h.report.contains("audio-recovery exhausted"))
        #expect(await h.resolver.availabilityCalls == 0)
        await h.player.stop()
    }

    @Test func interruptionWithoutResumePermissionLeavesRecoveredResourcesPaused() async throws {
        let h = try RecoveryHarness(audioRetryDelay: .milliseconds(150))
        try await h.play()
        await h.player.handleMediaServicesReset()
        await h.player.handleAudioSessionInterruption(.began(routeDisconnected: false))
        await h.player.handleAudioSessionInterruption(.ended(shouldResume: false))
        try await Task.sleep(for: .milliseconds(250))
        #expect(h.state.playbackState == .paused)
        #expect(h.engine.playCount == 1)
        #expect(h.report.contains("audio-recovery interrupted"))
        await h.player.stop()
    }

    @Test func networkChangeCannotRestartAnExhaustedAudioIncident() async throws {
        let h = try RecoveryHarness(audioStartupGrace: .milliseconds(100))
        try await h.play()
        await h.player.handleMediaServicesReset()
        try await h.waitUntil { h.report.contains("audio-recovery exhausted") }
        let plays = h.engine.playCount
        await h.player.handleNetworkPathChanged(NetworkPathEvent(
            generation: 1,
            descriptor: NetworkPathDescriptor(
                isOnline: true, isExpensive: true, isConstrained: false,
                supportsDNS: true, supportsIPv4: false, supportsIPv6: true,
                interfaces: [.cellular], gateways: []
            )
        ))
        try await Task.sleep(for: .milliseconds(200))
        #expect(h.engine.playCount == plays)
        #expect(await h.resolver.availabilityCalls == 0)
        guard case .error(.audioSystemUnavailable) = h.state.playbackState else {
            Issue.record("A network event replaced the audio-system failure")
            await h.player.stop()
            return
        }
        await h.player.stop()
    }

    @Test func routeLossDuringValidationNeverCompletesOnSpeaker() async throws {
        let h = try RecoveryHarness()
        try await h.play()
        await h.player.handleMediaServicesReset()
        try await h.waitUntil { h.engine.playCount == 2 }
        h.engine.startAdvancing()
        await h.player.handleEngineState(.playing, playbackToken: h.engine.token)
        // Route notifications may be delayed: the validator must inspect the live route itself.
        h.audioSession.outputs = [RecoveryTestAudioSession.speaker]
        try await Task.sleep(for: .milliseconds(350))
        #expect(!h.report.contains("audio-recovery progress-validated"))
        #expect(h.engine.isReady)
        h.audioSession.outputs = [RecoveryTestAudioSession.headphones]
        try await h.waitUntil { h.engine.playCount == 3 }
        try await confirmAudioResumed(h)
        await h.player.stop()
    }

    @Test func seekDuringRecoveryReplacesTheCheckpoint() async throws {
        let h = try RecoveryHarness(audioRetryDelay: .milliseconds(150))
        try await h.play()
        h.state.position = 37
        await h.player.handleMediaServicesReset()
        await h.player.seek(to: 62)
        try await h.waitUntil { h.engine.playCount == 2 }
        await h.player.handleEngineState(.playing, playbackToken: h.engine.token)
        #expect(h.engine.progress == 62)
        try await confirmAudioResumed(h)
        await h.player.stop()
    }

    @Test func queueUndoSurvivesNextWithoutRestartingPlayback() async throws {
        let h = try RecoveryHarness(startupGrace: .seconds(10))
        try await h.play(["a", "b", "c", "d"])
        let selection = try #require(QueueTrackSelection(playerState: h.state, destinationIndex: 1, destinationTrackID: "b"))
        let removal = try #require(await h.player.removeQueueTrack(selection))
        try await h.player.skipToNext()
        #expect(h.state.currentTrack?.id == "c")
        let plays = h.engine.playCount
        #expect(await h.player.restoreQueueTrack(removal))
        #expect(h.state.queue.map(\.id) == ["a", "b", "c", "d"])
        #expect(h.state.currentIndex == 2)
        #expect(h.state.currentTrack?.id == "c")
        #expect(h.engine.playCount == plays)
        await h.player.stop()
    }

    @Test func ordinaryNextDoesNotPresentAReconnection() async throws {
        let h = try RecoveryHarness(startupGrace: .seconds(2))
        try await h.play()
        for _ in 0..<3 {
            await h.player.handleEngineState(.buffering, playbackToken: h.engine.token)
        }
        #expect(h.state.waitingReason != .reconnecting)
        h.engine.startAdvancing()
        await h.player.handleEngineState(.playing, playbackToken: h.engine.token)
        try await h.player.skipToNext()
        #expect(h.state.currentTrack?.id == "b")
        for _ in 0..<3 {
            await h.player.handleEngineState(.buffering, playbackToken: h.engine.token)
        }
        #expect(h.state.waitingReason != .reconnecting)
        #expect(!h.report.contains("attempt-started"))
        await h.player.stop()
    }
    @Test func slowStartupAndRepeatedBufferingDoNotRebuildEarly() async throws {
        let h = try RecoveryHarness(startupGrace: .seconds(2))
        try await h.play()
        for _ in 0..<8 {
            await h.player.handleEngineState(.buffering, playbackToken: h.engine.token)
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(h.engine.playCount == 1)
        h.engine.startAdvancing()
        await h.player.handleEngineState(.playing, playbackToken: h.engine.token)
        try await h.waitUntil { h.report.contains("progress-validated") }
        #expect(h.engine.playCount == 1)
        #expect(h.state.playbackState == .playing)
        await h.player.stop()
    }

    @Test func thirdRebuildCanActuallyStartAndValidate() async throws {
        let h = try RecoveryHarness()
        try await h.play()
        try await h.waitUntil { h.engine.playCount == 4 }
        let stops = h.engine.stopCount
        for _ in 0..<6 {
            await h.player.handleEngineState(.buffering, playbackToken: h.engine.token)
        }
        #expect(h.engine.stopCount == stops)
        #expect(h.state.playbackState == .playing)
        #expect(h.state.waitingReason == .reconnecting)
        h.engine.startAdvancing()
        await h.player.handleEngineState(.playing, playbackToken: h.engine.token)
        try await h.waitUntil { h.report.contains("progress-validated") }
        #expect(!h.report.contains("retry-budget-exhausted"))
        #expect(h.engine.playCount == 4)
        await h.player.stop()
    }

    @Test func stalledLastAttemptStopsOnceAndManualNextStillWorks() async throws {
        let h = try RecoveryHarness()
        try await h.play()
        try await h.waitUntil { if case .error = h.state.playbackState { true } else { false } }
        #expect(h.engine.playCount == 4)
        #expect(h.report.components(separatedBy: "retry-budget-exhausted").count == 2)
        let oldToken = h.engine.token
        try await h.player.skipToNext()
        await h.player.handleEngineError(.init(error: URLError(.timedOut)), playbackToken: oldToken)
        #expect(h.state.currentTrack?.id == "b")
        #expect(h.state.playbackState == .playing)
        #expect(h.engine.playCount == 5)
        await h.player.stop()
    }

    @Test func explicitPlayAfterExhaustionGetsAFreshBudget() async throws {
        let h = try RecoveryHarness()
        try await h.play()
        try await h.waitUntil { if case .error = h.state.playbackState { true } else { false } }
        await h.player.resume()
        #expect(h.engine.playCount == 5)
        h.engine.startAdvancing()
        await h.player.handleEngineState(.playing, playbackToken: h.engine.token)
        try await h.waitUntil { h.report.contains("progress-validated") }
        #expect(h.state.playbackState == .playing)
        await h.player.stop()
    }

    @Test func confirmedMissingSongAdvancesWithoutChangingTheQueue() async throws {
        let h = try RecoveryHarness()
        await h.resolver.configure(missing: ["a"])
        try await h.play()
        await h.player.handleEngineError(.init(error: URLError(.badServerResponse)), playbackToken: h.engine.token)
        try await h.waitUntil { h.state.currentTrack?.id == "b" }
        #expect(h.state.queue.map(\.id) == ["a", "b"])
        #expect(h.engine.playCount == 2)
        #expect(h.report.contains("media-availability=missing"))
        await h.player.stop()
    }

    @Test func anEntireMissingQueueStopsEvenWithRepeatAllAndDuplicates() async throws {
        let h = try RecoveryHarness()
        await h.resolver.configure(missing: ["a", "b"])
        try await h.play(["a", "a", "b"])
        h.state.repeatMode = .all
        try await h.waitUntil { h.report.contains("unavailable-track has-next=false") }
        #expect(h.engine.playCount == 2)
        #expect(h.state.queue.count == 3)
        if case .error(.mediaNotFound) = h.state.playbackState {} else { Issue.record("Expected missing-media error") }
        await h.player.stop()
    }

    @Test func pauseWinsOverASuspendedMissingSongLookup() async throws {
        let h = try RecoveryHarness()
        await h.resolver.configure(block: true)
        try await h.play()
        try await h.waitUntil { await h.resolver.availabilityCalls == 1 }
        await h.player.pause()
        await h.resolver.releaseAvailability(.missing)
        try await Task.sleep(for: .milliseconds(100))
        #expect(h.state.currentTrack?.id == "a")
        #expect(h.state.playbackState == .paused)
        #expect(h.engine.playCount == 1)
        await h.player.stop()
    }

    @Test func nextWinsOverASuspendedMissingSongLookup() async throws {
        let h = try RecoveryHarness()
        await h.resolver.configure(block: true)
        try await h.play()
        try await h.waitUntil { await h.resolver.availabilityCalls == 1 }
        try await h.player.skipToNext()
        await h.resolver.releaseAvailability(.missing)
        try await Task.sleep(for: .milliseconds(100))
        #expect(h.state.currentTrack?.id == "b")
        #expect(h.state.playbackState == .playing)
        #expect(h.engine.playCount == 2)
        await h.player.stop()
    }
    @Test func pauseWinsOverPlaylistPreparation() async throws {
        let h = try RecoveryHarness(startupGrace: .seconds(3))
        try await h.play()
        let tracks = h.state.queue
        let gate = PlaylistPreparationGate()
        let request = Task {
            try await h.player.play(preparingQueue: {
                await gate.wait()
                return PreparedPlaybackQueue(tracks: tracks, startIndex: 1)
            })
        }
        try await h.waitUntil { await gate.isWaiting }
        await h.player.pause()
        await gate.release()
        try await request.value
        #expect(h.state.currentTrack?.id == "a")
        #expect(h.state.playbackState == .paused)
        #expect(h.engine.playCount == 1)
        await h.player.stop()
    }

}

private actor PlaylistPreparationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
