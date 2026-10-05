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
        var resumes = 0
        var stops = 0
        var resets = 0
        var airPlayActive = false
        var cancelledPreloads = 0
        var poisoned = false
        var active = false
        var volume: Float = 1
        var playingSince: Date?
        var position: Double = 0
        var failNextSeek = false
        var sourceURL: URL?
        var duration: Double = 120
    }
    private let storage = Mutex(Storage())
    var delegate: AudioEngineDelegate? {
        get { storage.withLock { $0.delegate } }
        set { storage.withLock { $0.delegate = newValue } }
    }
    var playCount: Int { storage.withLock { $0.plays } }
    var sourceURL: URL? { storage.withLock { $0.sourceURL } }
    var stopCount: Int { storage.withLock { $0.stops } }
    var resetCount: Int { storage.withLock { $0.resets } }
    func poisonMediaServices() { storage.withLock { $0.poisoned = true; $0.playingSince = nil } }
    var token: AudioEnginePlaybackToken { .init(rawValue: UInt64(playCount)) }
    func play(trackID: String, url: URL, headers: [String: String]) -> AudioEnginePlaybackToken {
        storage.withLock {
            $0.plays += 1
            $0.sourceURL = url
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
    func stallAtCurrentPosition() {
        storage.withLock {
            $0.position += $0.playingSince.map { Date().timeIntervalSince($0) } ?? 0
            $0.playingSince = nil
        }
    }
    func pause() { storage.withLock { $0.playingSince = nil } }
    func resume() { storage.withLock { $0.resumes += 1 } }
    var resumeCount: Int { storage.withLock { $0.resumes } }
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
    func failNextSeek() { storage.withLock { $0.failNextSeek = true } }
    func seek(to seconds: Double) async -> Bool {
        storage.withLock {
            if $0.failNextSeek { $0.failNextSeek = false; return false }
            $0.position = seconds
            return true
        }
    }
    var volume: Float {
        get { storage.withLock { $0.volume } }
        set { storage.withLock { $0.volume = newValue } }
    }
    var progress: Double {
        storage.withLock { $0.position + ($0.playingSince.map { Date().timeIntervalSince($0) } ?? 0) }
    }
    var duration: Double {
        get { storage.withLock { $0.duration } }
        set { storage.withLock { $0.duration = newValue } }
    }
    var isSeekable: Bool { true }
    var isReady: Bool { storage.withLock { !$0.active } }
    func applyReplayGain(dB: Float) {}
    var airPlayActive: Bool { storage.withLock { $0.airPlayActive } }
    var cancelledPreloads: Int { storage.withLock { $0.cancelledPreloads } }
    func setAirPlayActive(_ active: Bool) {
        storage.withLock {
            if $0.airPlayActive != active { $0.cancelledPreloads += 1 }
            $0.airPlayActive = active
        }
    }
    func cancelPreload() { storage.withLock { $0.cancelledPreloads += 1 } }
    func setTrackDuration(_ seconds: Double) {}
    func preloadNext(trackID: String, url: URL, headers: [String: String], crossfadeDuration: Double, replayGainDB: Float) {}
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
    private var playbackFileURL: URL?
    func usePlaybackFile(_ url: URL) { playbackFileURL = url }
    var usesDownloadedSource = false
    var transcoded = false
    func useTranscode() { transcoded = true }
    var usesCachedSource = false
    func useCachedSource() { usesCachedSource = true }
    func localSource(songId: String, serverId: UUID) async -> MediaSource? {
        if let playbackFileURL { return .downloaded(playbackFileURL) }
        if usesDownloadedSource { return .downloaded(URL(fileURLWithPath: "/tmp/recovery-test-audio.m4a")) }
        if usesCachedSource { return .cached(URL(fileURLWithPath: "/tmp/recovery-test-cache.m4a")) }
        return nil
    }
    func useDownloadedSource() { usesDownloadedSource = true }
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
        if let local = await localSource(songId: songId, serverId: serverId) { return local }
        return .stream(URL(string: transcoded ? "https://playback.invalid/stream?format=mp3&maxBitRate=192" : "https://playback.invalid/stream")!, customHeaders: [:])
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
    let replayGainSettings: ReplayGainSettings
    let crossfadeSettings: CrossfadeSettings

    init(
        startupGrace: Duration = .milliseconds(600),
        stallGrace: Duration = .milliseconds(100),
        audioStartupGrace: Duration = .milliseconds(800),
        audioRetryDelay: Duration = .milliseconds(40),
        localMusicStore: LocalMusicStore? = nil,
        configureServer: Bool = true,
        engineOverride: (any AudioEngine)? = nil,
        crossfadeDuration: Double = 0,
        seekFileLoader: @escaping @Sendable (MediaSource) async throws -> MediaSource = { try await TranscodedSeekFile.prepare($0) }
    ) throws {
        let container = try ModelContainer.minidisc(inMemory: true)
        let server = MockServerService()
        server.state.activeServer = ServerSnapshot(from: ServerConfig(
            displayName: "Test", baseURL: "https://playback.invalid", username: "test"
        ))
        if !configureServer { server.state.activeServer = nil }
        let toast = ToastService()
        let download = DownloadService(serverService: server, modelContainer: container, toastService: toast)
        let cacheSettings = CacheSettings(defaults: defaults)
        cacheSettings.cacheFormat = .flacOriginal // The stub server cannot create background cache URLs.
        let crossfade = CrossfadeSettings(defaults: defaults)
        crossfade.duration = crossfadeDuration
        crossfadeSettings = crossfade
        replayGainSettings = ReplayGainSettings(defaults: defaults)
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
            replayGainSettings: replayGainSettings,
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
            engine: engineOverride ?? engine,
            networkRecoveryTiming: .init(
                startupGrace: startupGrace, stallGrace: stallGrace,
                retryDelay: .milliseconds(40), validationDelay: .milliseconds(200)
            ),
            audioSession: audioSession,
            audioRecoveryTiming: .init(
                retryDelay: audioRetryDelay, routeGrace: .seconds(2),
                startupGrace: audioStartupGrace, pollInterval: .milliseconds(10)
            ),
            localMusicStore: localMusicStore,
            seekFileLoader: seekFileLoader
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

@Suite("Playback continuity during buffering", .serialized)
@MainActor
struct PlaybackContinuityIntegrationTests {
    @Test(arguments: [false, true])
    func bufferingWhileAudioAdvancesDoesNotRebuildAndStillDetectsALaterStall(cached: Bool) async throws {
        let h = try RecoveryHarness(startupGrace: .milliseconds(400), stallGrace: .milliseconds(250))
        try await h.play(["a"])
        try await h.waitUntil { h.report.contains("engine state=buffering") }
        h.engine.startAdvancing()
        await h.player.handleEngineState(.playing, playbackToken: h.engine.token)
        try await h.waitUntil { h.report.contains("progress-validated") }
        if cached { await h.resolver.useCachedSource() }
        let position = h.engine.progress
        await h.player.handleEngineState(.buffering, playbackToken: h.engine.token)
        try await Task.sleep(for: .milliseconds(750))
        #expect(h.engine.playCount == 1)
        #expect(h.engine.progress > position + 0.5)
        #expect(await h.resolver.availabilityCalls == 0)
        // No new state callback: the continuing observation must catch the actual stall.
        h.engine.stallAtCurrentPosition()
        let stalledPosition = h.engine.progress
        try await h.waitUntil { h.engine.playCount == 2 }
        await h.player.handleEngineState(.playing, playbackToken: h.engine.token)
        #expect(h.engine.progress >= stalledPosition)
        await h.player.stop()
    }

    @Test func recoveryRechecksProgressAfterResolvingTheReplacement() async throws {
        let h = try RecoveryHarness(startupGrace: .milliseconds(400))
        try await h.play(["a"])
        try await h.waitUntil { h.report.contains("engine state=buffering") }
        _ = await h.engine.seek(to: 37)
        h.state.position = 37
        await h.resolver.blockResolution(of: "a")
        try await h.waitUntil { await h.resolver.isResolvingBlockedTrack }
        // The original decoder recovers while the resolver is suspended.
        h.engine.startAdvancing()
        try await Task.sleep(for: .milliseconds(250))
        await h.player.handleEngineState(.playing, playbackToken: h.engine.token)
        await h.resolver.releaseResolution()
        try await h.waitUntil { h.report.contains("progress-validated") || h.engine.playCount > 1 }
        #expect(h.engine.playCount == 1)
        #expect(h.engine.progress > 37.2)
        await h.player.stop()
    }

    @Test func requiredRebuildUsesTheLatestClockInsteadOfAnEarlierSnapshot() async throws {
        let h = try RecoveryHarness(startupGrace: .milliseconds(400))
        try await h.play(["a"])
        try await h.waitUntil { h.report.contains("engine state=buffering") }
        _ = await h.engine.seek(to: 37)
        h.state.position = 37
        await h.resolver.blockResolution(of: "a")
        try await h.waitUntil { await h.resolver.isResolvingBlockedTrack }
        // A final few frames render during resolution, below the sustained-progress threshold.
        _ = await h.engine.seek(to: 37.05)
        await h.resolver.releaseResolution()
        try await h.waitUntil { h.engine.playCount == 2 }
        await h.player.handleEngineState(.playing, playbackToken: h.engine.token)
        #expect(h.engine.progress == 37.05)
        await h.player.stop()
    }
}

@Suite("Preload continuity across environment and settings changes", .serialized)
@MainActor
struct PreloadContinuityIntegrationTests {
    @Test(arguments: [false, true])
    func enginesWithoutNativeReconnectionInvalidateOnlyRemotePreparation(local: Bool) async throws {
        let h = try RecoveryHarness(startupGrace: .seconds(30))
        if local { await h.resolver.useDownloadedSource() }
        try await h.play(["a", "b"])
        h.engine.duration = 10
        h.engine.startAdvancing()
        await h.player.handleEngineState(.playing, playbackToken: h.engine.token)
        try await h.waitUntil { h.report.contains("transition-prepared=native-queue") }
        let cancellations = h.engine.cancelledPreloads
        await h.player.handleNetworkPathChanged(NetworkPathEvent(
            generation: 1,
            descriptor: NetworkPathDescriptor(
                isOnline: false, isExpensive: false, isConstrained: false,
                supportsDNS: false, supportsIPv4: false, supportsIPv6: false,
                interfaces: [], gateways: []
            )
        ))
        #expect(h.engine.cancelledPreloads == cancellations + (local ? 0 : 1))
        #expect(h.engine.playCount == 1)
        await h.player.stop()
    }

    @Test(arguments: ["network-remote", "network-local", "replayGain", "crossfade", "airPlay"])
    func preparedNativeQueueKeepsItsReader(change: String) async throws {
        let factory = StreamingDriverFactory()
        let engine = AudioStreamingEngine(driverFactory: { factory.make() })
        let h = try RecoveryHarness(startupGrace: .seconds(30), engineOverride: engine)
        defer { engine.stop() }
        if change == "network-local" { await h.resolver.useDownloadedSource() }
        try await h.play(["a", "b"])
        let reader = try #require(factory.drivers.first)
        reader.setPosition(2, progresses: true)
        try await h.waitUntil { reader.queuedCount == 1 }
        let position = engine.progress

        switch change {
        case "network-remote", "network-local":
            await h.player.handleNetworkPathChanged(NetworkPathEvent(
                generation: 1,
                descriptor: NetworkPathDescriptor(
                    isOnline: true, isExpensive: true, isConstrained: false,
                    supportsDNS: true, supportsIPv4: true, supportsIPv6: true,
                    interfaces: [.cellular], gateways: []
                )
            ))
        case "replayGain":
            let settings = h.replayGainSettings
            settings.enabled = true
            settings.preAmp = 3
            settings.preventClipping = false
            await h.player.replayGainSettingsDidChange()
        case "crossfade":
            // Changing a duration must not throw away an already-decoded sequential entry.
            h.crossfadeSettings.duration = 2
            await h.player.crossfadeSettingsDidChange()
        default:
            h.audioSession.outputs = [.init(uid: "airplay-test", portType: .airPlay)]
            await h.player.handleRouteChange(.unknown)
            h.audioSession.outputs = [RecoveryTestAudioSession.headphones]
            await h.player.handleRouteChange(.unknown)
        }

        #expect(factory.drivers.count == 1)
        #expect(!reader.wasStopped)
        #expect(reader.requestedSeek == nil)
        #expect(engine.progress >= position)
        reader.finish(startingNext: true)
        try await h.waitUntil { h.state.currentTrack?.id == "b" }
        #expect(factory.drivers.count == 1)
        #expect(h.state.currentIndex == 1)
        await h.player.stop()
    }

    @Test(arguments: [0.65, 1.0, 1.1])
    func coldResumeRestoresAlsoTheFirstSecond(position: Double) async throws {
        let h = try RecoveryHarness(startupGrace: .seconds(30))
        await h.resolver.useDownloadedSource()
        try await h.play(["a"])
        _ = await h.engine.seek(to: position)
        h.state.position = position
        h.engine.stop()
        await h.player.resume()
        #expect(h.engine.volume == 0)
        await h.player.handleEngineState(.playing, playbackToken: h.engine.token)
        #expect(h.engine.progress == position)
        #expect(h.engine.volume > 0)
        await h.player.stop()
    }
}

@Suite("Playback resume after an unended interruption", .serialized)
@MainActor
struct InterruptedSessionResumeTests {
    @Test func realStreamingDecoderResumesAndRecoversWithoutAnInterruptionEndEvent() async throws {
        try AVAudioSession.sharedInstance().setCategory(.playback)
        try AVAudioSession.sharedInstance().setActive(true)
        let url = try #require(Bundle(for: RecoveryAudioFixtureBundle.self).url(
            forResource: "stream-aac.m4a", withExtension: nil
        ))
        let engine = AudioStreamingEngine()
        engine.volume = 0
        let h = try RecoveryHarness(audioStartupGrace: .seconds(3), engineOverride: engine)
        defer { engine.stop() }
        await h.resolver.usePlaybackFile(url)
        try await h.play(["a"])
        try await h.waitUntil { h.state.position > 0.5 }
        await h.player.handleAudioSessionInterruption(.began(routeDisconnected: true))
        await h.player.resume()
        #expect(h.report.contains("interruption-superseded-by-playback"))
        let checkpoint = engine.progress
        await h.player.handleMediaServicesReset()
        try await h.waitUntil { h.report.contains("audio-recovery progress-validated") }
        #expect(h.state.currentTrack?.id == "a")
        #expect(engine.progress > checkpoint)
        #expect(h.state.waitingReason == nil)
        #expect(!h.report.contains("audio-recovery exhausted"))
        await h.player.stop()
    }

    @Test(arguments: [false, true])
    func explicitResumeAllowsRecoveryAfterALaterMediaServicesReset(resetWhilePaused: Bool) async throws {
        let h = try RecoveryHarness(startupGrace: .seconds(30))
        try await h.play(["a", "b"])
        _ = await h.engine.seek(to: 37)
        h.state.position = 37
        h.audioSession.outputs = [RecoveryTestAudioSession.speaker]
        await h.player.handleAudioSessionInterruption(.began(routeDisconnected: true))
        // As in the report: no interruption-ended event, but explicit Play succeeds.
        await h.player.resume()
        h.engine.startAdvancing()
        await h.player.handleEngineState(.playing, playbackToken: h.engine.token)
        await h.player.pause()
        if resetWhilePaused {
            let playsBeforeReset = h.engine.playCount
            await h.player.handleMediaServicesReset()
            #expect(h.engine.playCount == playsBeforeReset)
            #expect(h.state.playbackState == .paused)
        }
        await h.player.resume()
        let plays = h.engine.playCount
        h.engine.poisonMediaServices()
        await h.player.handleMediaServicesReset()
        // A delayed end of the old interruption must not pause this newer recovery.
        await h.player.handleAudioSessionInterruption(.ended(shouldResume: false))
        try await h.waitUntil { h.engine.playCount == plays + 1 }
        try await confirmRecovery(h)
        #expect(h.state.currentTrack?.id == "a")
        #expect(h.state.currentIndex == 0)
        #expect(h.engine.progress >= 37)
        #expect(h.state.waitingReason == nil)
        #expect(await h.resolver.availabilityCalls == 0)
        await h.player.stop()
    }

    @Test func newQueueCanSupersedeAnUnendedInterruption() async throws {
        let h = try RecoveryHarness(startupGrace: .seconds(30))
        try await h.play(["a"])
        await h.player.handleAudioSessionInterruption(.began(routeDisconnected: true))
        try await h.play(["b", "c"])
        await h.player.handleMediaServicesReset()
        try await h.waitUntil { h.engine.playCount == 3 }
        try await confirmRecovery(h)
        #expect(h.state.currentTrack?.id == "b")
        await h.player.stop()
    }

    @Test func failedActivationKeepsTheInterruptionUntilTheSystemEndsIt() async throws {
        let h = try RecoveryHarness(startupGrace: .seconds(30))
        try await h.play(["a"])
        await h.player.handleAudioSessionInterruption(.began(routeDisconnected: false))
        h.audioSession.failNextActivations(1)
        await h.player.resume()
        let activations = h.audioSession.activations
        let plays = h.engine.playCount
        await h.player.handleMediaServicesReset()
        try await Task.sleep(for: .milliseconds(150))
        #expect(h.audioSession.activations == activations)
        #expect(h.engine.playCount == plays)
        await h.player.handleAudioSessionInterruption(.ended(shouldResume: true))
        try await h.waitUntil { h.engine.playCount == plays + 1 }
        try await confirmRecovery(h)
        await h.player.stop()
    }

    @Test func activationRetryCannotSupersedeANewerInterruption() async throws {
        let h = try RecoveryHarness(startupGrace: .seconds(30))
        try await h.play(["a"])
        await h.player.handleAudioSessionInterruption(.began(routeDisconnected: true))
        h.audioSession.failNextActivations(1)
        await h.player.resume()
        let activations = h.audioSession.activations
        await h.player.handleAudioSessionInterruption(.began(routeDisconnected: false))
        // The queued 500-ms activation retry belongs to the older Play request.
        try await Task.sleep(for: .milliseconds(650))
        #expect(h.audioSession.activations == activations)
        await h.player.handleMediaServicesReset()
        let plays = h.engine.playCount
        try await Task.sleep(for: .milliseconds(150))
        #expect(h.engine.playCount == plays)
        await h.player.handleAudioSessionInterruption(.ended(shouldResume: true))
        try await h.waitUntil { h.engine.playCount == plays + 1 }
        try await confirmRecovery(h)
        await h.player.stop()
    }

    private func confirmRecovery(_ h: RecoveryHarness) async throws {
        try await h.waitUntil {
            let attempt = h.report.components(separatedBy: "audio-recovery attempt-started").last ?? ""
            return attempt.contains("engine state=paused") && attempt.contains("engine state=buffering")
        }
        h.engine.startAdvancing()
        await h.player.handleEngineState(.playing, playbackToken: h.engine.token)
        try await h.waitUntil { h.report.contains("audio-recovery progress-validated") }
    }
}

@Suite("Player recovery integration", .serialized)
@MainActor
struct PlayerRecoveryIntegrationTests {
    @Test(arguments: [false, true])
    func queuedHandoffResumesAfterTransportPause(pauseBeforePromotion: Bool) async throws {
        let players = Mutex<[AVQueuePlayer]>([])
        let engine = AVPlayerEngine(playerFactory: {
            let player = AVQueuePlayer()
            players.withLock { $0.append(player) }
            return player
        })
        let h = try RecoveryHarness(engineOverride: engine)
        // AirPlay policy is simulated; the media pipeline runs locally, without a receiver.
        h.audioSession.outputs = [.init(uid: "airplay-test", portType: .airPlay)]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).caf")
        defer { engine.stop(); try? FileManager.default.removeItem(at: url) }
        do {
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 80_000))
            buffer.frameLength = buffer.frameCapacity
            let samples = try #require(buffer.floatChannelData?[0])
            samples.initialize(repeating: 0, count: Int(buffer.frameLength))
            try file.write(from: buffer)
        }
        await h.resolver.usePlaybackFile(url)
        try await h.play(["a", "b", "c"])
        let active = try #require(players.withLock { $0.first })
        try await h.waitUntil { active.timeControlStatus == .playing && engine.progress > 0.1 }

        for (index, trackID) in [(1, "b"), (2, "c")] {
            let previous = try #require(active.currentItem)
            engine.preloadNext(trackID: trackID, url: url, headers: [:], crossfadeDuration: 0, replayGainDB: 0)
            let next = try #require(active.items().last)
            #expect(next !== previous)

            // Inject a transport pause, not a user pause, on either side of the native hand-off.
            if pauseBeforePromotion { active.pause() }
            active.advanceToNextItem()
            if !pauseBeforePromotion { active.pause() }

            try await h.waitUntil {
                h.state.currentIndex == index && active.currentItem === next
                    && active.timeControlStatus == .playing && engine.progress > 0.1
            }
            #expect(h.state.currentTrack?.id == trackID)
            #expect(h.state.wantsPlayback)
            #expect(active.items().count == 1)
            #expect(players.withLock { $0.count } == 2)
            #expect(players.withLock { $0[1].currentItem } == nil)
        }
        #expect(!h.report.contains("item-rebuilt"))
        #expect(!h.report.contains("track-end-ignored"))
        #expect(h.report.components(separatedBy: "playback track-ended ").count - 1 == 2)
        await h.player.stop()
    }

    @Test(arguments: [false, true])
    func stalledStreamUsesNewlyCompletedCacheWithoutServerProbe(offline: Bool) async throws {
        // Keep startup recovery out of the fixture setup; this test triggers a later stall.
        let h = try RecoveryHarness(startupGrace: .seconds(3))
        try await h.play()
        try await h.waitUntil { h.report.contains("engine state=buffering") }
        _ = await h.engine.seek(to: 37)
        h.state.position = 37
        await h.player.handleEngineState(.playing, playbackToken: h.engine.token)
        // The track was remote at startup; its cache copy becomes available later.
        await h.resolver.useCachedSource()
        if offline {
            await h.player.handleNetworkPathChanged(NetworkPathEvent(
                generation: 1,
                descriptor: NetworkPathDescriptor(
                    isOnline: false, isExpensive: true, isConstrained: false,
                    supportsDNS: false, supportsIPv4: false, supportsIPv6: false,
                    interfaces: [.cellular], gateways: []
                )
            ))
        }
        await h.player.handleEngineState(.buffering, playbackToken: h.engine.token)
        try await h.waitUntil { h.engine.playCount == 2 }
        try await h.waitUntil {
            h.report.components(separatedBy: "item-rebuilt").count > 1
        }
        #expect(h.engine.sourceURL?.lastPathComponent == "recovery-test-cache.m4a")
        #expect(await h.resolver.availabilityCalls == 0)
        #expect(h.state.position == 37)
        #expect(h.state.currentTrack?.id == "a")
        #expect(h.report.contains("playback source=cache"))
        h.engine.startAdvancing()
        await h.player.handleEngineState(.playing, playbackToken: h.engine.token)
        try await h.waitUntil { h.report.contains("progress-validated") }
        #expect(h.engine.progress >= 37)
        #expect(h.engine.volume > 0)
        await h.player.stop()
    }

    @Test(arguments: [false, true])
    func loadingReplacementKeepsTheResumePosition(downloaded: Bool) async throws {
        let h = try RecoveryHarness(startupGrace: .seconds(3))
        if downloaded { await h.resolver.useDownloadedSource() }
        try await h.play()
        _ = await h.engine.seek(to: 37)
        h.state.position = 37
        h.engine.stop()
        await h.player.resume()
        #expect(h.engine.playCount == 2)
        // At least one real progress-timer tick while the replacement is still loading at zero.
        try await Task.sleep(for: .milliseconds(750))
        #expect(h.state.position == 37)
        await h.player.pause()
        #expect(h.state.position == 37)
        await h.player.stop()
    }

    @Test(arguments: [false, true])
    func failedRestoreNeverPlaysFromTheBeginning(downloaded: Bool) async throws {
        let h = try RecoveryHarness(startupGrace: .seconds(3))
        if downloaded { await h.resolver.useDownloadedSource() }
        try await h.play()
        _ = await h.engine.seek(to: 37)
        h.state.position = 37
        h.engine.stop()
        await h.player.resume()
        try await h.waitUntil {
            h.report.components(separatedBy: "engine state=buffering").count >= 3
        }
        h.engine.failNextSeek()
        h.engine.startAdvancing()
        await h.player.handleEngineState(.playing, playbackToken: h.engine.token)
        #expect(h.engine.isReady)
        #expect(h.state.position == 37)
        if case .error = h.state.playbackState {} else {
            Issue.record("Failed restore must stop safely instead of unmuting the song at zero")
        }
        // A manual retry must still use the original checkpoint.
        await h.player.resume()
        await h.player.handleEngineState(.playing, playbackToken: h.engine.token)
        #expect(h.engine.progress >= 37)
        #expect(h.engine.volume > 0)
        await h.player.stop()
    }

    @Test func airPlayRouteUsesSinglePlayerTransitionsAndRestoresLocalMode() async throws {
        let h = try RecoveryHarness()
        h.audioSession.outputs = [.init(uid: "airplay-test", portType: .airPlay)]
        try await h.play(["a", "b"])
        #expect(h.engine.airPlayActive)
        #expect(h.report.contains("airplay=true crossfade-policy=disabled"))
        await h.player.handleEndOfTrack(.init(endedPlaybackToken: h.engine.token, endedPosition: 120, promotedPlayback: nil))
        #expect(h.state.currentTrack?.id == "b")
        #expect(h.state.wantsPlayback)
        #expect(h.engine.airPlayActive)

        h.audioSession.outputs = [RecoveryTestAudioSession.headphones]
        await h.player.handleRouteChange(.routeConfigurationChange)
        #expect(!h.engine.airPlayActive)
        #expect(h.report.contains("airplay=false crossfade-policy=per-transition"))
        let cancelled = h.engine.cancelledPreloads
        h.audioSession.outputs = [.init(uid: "airplay-test", portType: .airPlay)]
        await h.player.handleRouteChange(.unknown)
        #expect(h.engine.airPlayActive)
        #expect(h.engine.cancelledPreloads > cancelled)
        #expect(h.state.currentTrack?.id == "b")
        await h.player.stop()
    }

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
        await PlaybackCommandOrigin.$current.withValue(.remotePause) {
            await h.player.pause()
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(h.engine.playCount == 1)
        #expect(h.state.playbackState == .paused)
        #expect(h.report.contains("pause-origin=remote-pause audio-recovery=true"))
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
        let timeline = try #require(h.report.components(separatedBy: "=== TIMELINE").last)
        #expect(timeline.components(separatedBy: "retry-budget-exhausted").count == 2)
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
                return PreparedPlaybackQueue(tracks: tracks, startIndex: 1, repeatMode: .all)
            })
        }
        try await h.waitUntil { await gate.isWaiting }
        await h.player.pause()
        await gate.release()
        try await request.value
        #expect(h.state.currentTrack?.id == "a")
        #expect(h.state.playbackState == .paused)
        #expect(h.engine.playCount == 1)
        #expect(h.state.repeatMode == .off)
        await h.player.stop()
    }

    @Test func preparedPlaybackAppliesExplicitRepeatMode() async throws {
        let h = try RecoveryHarness(startupGrace: .seconds(3))
        try await h.play()
        let tracks = h.state.queue
        try await h.player.play(preparingQueue: {
            PreparedPlaybackQueue(tracks: tracks, startIndex: 0, repeatMode: .all)
        })
        #expect(h.state.repeatMode == .all)
        await h.player.stop()
    }
}

private actor PlaylistPreparationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}


@Suite @MainActor
struct LocalMusicPlaybackTests {
    @Test func localQueuePlaysAndAdvancesWithoutAServer() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Music")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try LocalMusicFixture.wav(at: folder.appendingPathComponent("First.wav"))
        try LocalMusicFixture.wav(at: folder.appendingPathComponent("Second.wav"))
        let store = LocalMusicStore(directory: root.appendingPathComponent("Index"))
        try await store.add([folder])
        let songs = try await store.refresh().tracks.map(\.song)
        let harness = try RecoveryHarness(localMusicStore: store, configureServer: false)
        try await harness.player.play(tracks: songs, startIndex: 0)
        #expect(harness.engine.sourceURL?.lastPathComponent == "First.wav")
        #expect(harness.state.currentTrack?.isLocalFile == true)
        try await harness.player.skipToNext()
        #expect(harness.engine.sourceURL?.lastPathComponent == "Second.wav")
        await harness.player.pause()
        try FileManager.default.removeItem(at: folder.appendingPathComponent("Second.wav"))
        await harness.player.resume()
        #expect(harness.state.playbackState == .paused)
        await harness.player.stop()
    }
}

private actor SeekFileLoaderProbe {
    var received: [MediaSource] = []
    private var pending: [CheckedContinuation<MediaSource, Error>] = []
    func load(_ source: MediaSource) async throws -> MediaSource {
        received.append(source)
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func complete() {
        pending.removeFirst().resume(returning: .seekBuffer(TranscodedSeekFile(
            url: URL(fileURLWithPath: "/tmp/minidisc-seek-fixture-\(UUID()).mp3")
        )))
    }
    func fail() { pending.removeFirst().resume(throwing: URLError(.timedOut)) }
}

@Suite("Transcoded seek integration", .serialized)
@MainActor
struct TranscodedSeekIntegrationTests {
    @Test func preparesSameQualityThenSeeksWithoutChangingQueue() async throws {
        let probe = SeekFileLoaderProbe()
        let h = try RecoveryHarness(startupGrace: .seconds(30), seekFileLoader: { try await probe.load($0) })
        await h.resolver.useTranscode()
        try await h.play()
        let seek = Task { await h.player.seek(to: 80) }
        try await h.waitUntil { await probe.received.count == 1 }
        let source = try #require(await probe.received.first)
        #expect(source.url.query?.contains("maxBitRate=192") == true)
        #expect(h.engine.playCount == 1)
        let resumesBeforeCompletion = h.engine.resumeCount
        await probe.complete()
        await seek.value
        #expect(h.engine.playCount == 2)
        #expect(h.engine.sourceURL?.isFileURL == true)
        #expect(h.engine.progress == 80)
        #expect(h.state.position == 80)
        #expect(h.state.currentIndex == 0)
        #expect(h.state.queue.count == 2)
        #expect(h.engine.resumeCount == resumesBeforeCompletion + 1)
        #expect(h.report.contains("landed=80.00s success=true stale=false"))
        await h.player.seek(to: 20)
        #expect(await probe.received.count == 1)
        #expect(h.engine.playCount == 2)
        #expect(h.engine.progress == 20)
        await h.player.stop()
    }

    @Test func pauseDuringPreparationDoesNotReplaceOrResume() async throws {
        let probe = SeekFileLoaderProbe()
        let h = try RecoveryHarness(startupGrace: .seconds(30), seekFileLoader: { try await probe.load($0) })
        await h.resolver.useTranscode()
        try await h.play()
        let seek = Task { await h.player.seek(to: 80) }
        try await h.waitUntil { await probe.received.count == 1 }
        await h.player.pause()
        let resumesBeforeCompletion = h.engine.resumeCount
        await probe.complete()
        await seek.value
        #expect(h.engine.playCount == 1)
        #expect(h.engine.resumeCount == resumesBeforeCompletion)
        #expect(h.state.playbackState == .paused)
        await h.player.stop()
    }

    @Test func newerTrackWinsOverCompletedPreparation() async throws {
        let probe = SeekFileLoaderProbe()
        let h = try RecoveryHarness(startupGrace: .seconds(30), seekFileLoader: { try await probe.load($0) })
        await h.resolver.useTranscode()
        try await h.play()
        let seek = Task { await h.player.seek(to: 80) }
        try await h.waitUntil { await probe.received.count == 1 }
        try await h.player.skipToNext()
        let playCount = h.engine.playCount
        await probe.complete()
        await seek.value
        #expect(h.engine.playCount == playCount)
        #expect(h.state.currentIndex == 1)
        #expect(h.engine.sourceURL?.isFileURL == false)
        await h.player.stop()
    }

    @Test func failedPreparationKeepsExistingAudioAndReportsFailure() async throws {
        let probe = SeekFileLoaderProbe()
        let h = try RecoveryHarness(startupGrace: .seconds(30), seekFileLoader: { try await probe.load($0) })
        await h.resolver.useTranscode()
        try await h.play()
        _ = await h.engine.seek(to: 25)
        let seek = Task { await h.player.seek(to: 80) }
        try await h.waitUntil { await probe.received.count == 1 }
        await probe.fail()
        await seek.value
        #expect(h.engine.playCount == 1)
        #expect(h.engine.progress == 25)
        #expect(h.report.contains("success=false stale=false"))
        await h.player.stop()
    }

    @Test func mostRecentSeekWinsDuringPreparation() async throws {
        let probe = SeekFileLoaderProbe()
        let h = try RecoveryHarness(startupGrace: .seconds(30), seekFileLoader: { try await probe.load($0) })
        await h.resolver.useTranscode()
        try await h.play()
        let first = Task { await h.player.seek(to: 80) }
        try await h.waitUntil { await probe.received.count == 1 }
        let second = Task { await h.player.seek(to: 40) }
        try await h.waitUntil { h.report.contains("target=40.00s") }
        #expect(await probe.received.count == 1)
        await probe.complete()
        await first.value
        await second.value
        #expect(await probe.received.count == 1)
        #expect(h.engine.playCount == 2)
        #expect(h.engine.progress == 40)
        await h.player.stop()
    }

    @Test func pauseCancelsSharedPreparationWithoutResumingEitherSeek() async throws {
        let probe = SeekFileLoaderProbe()
        let h = try RecoveryHarness(startupGrace: .seconds(30), seekFileLoader: { try await probe.load($0) })
        await h.resolver.useTranscode()
        try await h.play()
        let first = Task { await h.player.seek(to: 80) }
        try await h.waitUntil { await probe.received.count == 1 }
        let second = Task { await h.player.seek(to: 40) }
        try await h.waitUntil { h.report.contains("target=40.00s") }
        await h.player.pause()
        let resumes = h.engine.resumeCount
        await probe.complete()
        await first.value
        await second.value
        #expect(await probe.received.count == 1)
        #expect(h.engine.playCount == 1)
        #expect(h.engine.resumeCount == resumes)
        #expect(h.state.playbackState == .paused)
        await h.player.stop()
    }

    @Test func sharedPreparationFailureAllowsANewAttempt() async throws {
        let probe = SeekFileLoaderProbe()
        let h = try RecoveryHarness(startupGrace: .seconds(30), seekFileLoader: { try await probe.load($0) })
        await h.resolver.useTranscode()
        try await h.play()
        let first = Task { await h.player.seek(to: 80) }
        try await h.waitUntil { await probe.received.count == 1 }
        let second = Task { await h.player.seek(to: 40) }
        try await h.waitUntil { h.report.contains("target=40.00s") }
        await probe.fail()
        await first.value
        await second.value
        #expect(await probe.received.count == 1)
        #expect(h.engine.playCount == 1)
        let retry = Task { await h.player.seek(to: 60) }
        try await h.waitUntil { await probe.received.count == 2 }
        await probe.complete()
        await retry.value
        #expect(h.engine.playCount == 2)
        #expect(h.engine.progress == 60)
        await h.player.stop()
    }

    @Test func failedLocalSeekStopsBeforeMakingWrongPositionAudible() async throws {
        let probe = SeekFileLoaderProbe()
        let h = try RecoveryHarness(startupGrace: .seconds(30), seekFileLoader: { try await probe.load($0) })
        await h.resolver.useTranscode()
        try await h.play()
        let seek = Task { await h.player.seek(to: 80) }
        try await h.waitUntil { await probe.received.count == 1 }
        h.engine.failNextSeek()
        let resumesBeforeCompletion = h.engine.resumeCount
        await probe.complete()
        try await h.waitUntil { if case .error = h.state.playbackState { return true }; return false }
        await seek.value
        #expect(h.engine.resumeCount == resumesBeforeCompletion)
        #expect(h.engine.stopCount > 0)
        await h.player.stop()
    }

    @Test func originalUsesNativeSeekAndPausedTranscodeStaysPaused() async throws {
        let probe = SeekFileLoaderProbe()
        let h = try RecoveryHarness(startupGrace: .seconds(30), seekFileLoader: { try await probe.load($0) })
        try await h.play()
        await h.player.seek(to: 30)
        #expect(await probe.received.isEmpty)
        #expect(h.engine.progress == 30)
        await h.resolver.useTranscode()
        try await h.play()
        await h.player.pause()
        let resumesBeforeCompletion = h.engine.resumeCount
        let seek = Task { await h.player.seek(to: 80) }
        try await h.waitUntil { await probe.received.count == 1 }
        await probe.complete()
        await seek.value
        #expect(h.engine.progress == 80)
        #expect(h.engine.resumeCount == resumesBeforeCompletion)
        #expect(h.state.playbackState == .paused)
        await h.player.stop()
    }
}


@Suite("AudioStreaming playback presentation", .serialized)
@MainActor
struct AudioStreamingPresentationIntegrationTests {
    @Test func networkChangePreservesTheRealDecodedQueue() async throws {
        try AVAudioSession.sharedInstance().setCategory(.playback)
        try AVAudioSession.sharedInstance().setActive(true)
        let url = try #require(Bundle(for: RecoveryAudioFixtureBundle.self).url(
            forResource: "stream-aac.m4a", withExtension: nil
        ))
        let readers = Mutex(0)
        let engine = AudioStreamingEngine(driverFactory: {
            readers.withLock { $0 += 1 }
            return AudioStreamingDriver()
        })
        engine.volume = 0
        let h = try RecoveryHarness(engineOverride: engine)
        defer { engine.stop() }
        await h.resolver.usePlaybackFile(url)
        try await h.play(["a", "b"])
        try await h.waitUntil {
            h.state.position > 1 && h.report.contains("transition-prepared=native-queue")
        }
        let position = engine.progress
        await h.player.handleNetworkPathChanged(NetworkPathEvent(
            generation: 1,
            descriptor: NetworkPathDescriptor(
                isOnline: true, isExpensive: true, isConstrained: false,
                supportsDNS: true, supportsIPv4: true, supportsIPv6: true,
                interfaces: [.cellular], gateways: []
            )
        ))
        #expect(readers.withLock { $0 } == 1)
        #expect(engine.progress >= position)
        try await h.waitUntil { h.state.currentTrack?.id == "b" && h.state.position > 0.2 }
        #expect(readers.withLock { $0 } == 1)
        #expect(h.state.waitingReason == nil)
        #expect(abs(h.state.duration - 6) < 0.15)
        await h.player.stop()
    }

    @Test func manualNextAfterRepeatedSeeksKeepsTheQueueAndClockTogether() async throws {
        try AVAudioSession.sharedInstance().setCategory(.playback)
        try AVAudioSession.sharedInstance().setActive(true)
        let url = try #require(Bundle(for: RecoveryAudioFixtureBundle.self).url(
            forResource: "stream-aac.m4a", withExtension: nil
        ))
        let engine = AudioStreamingEngine()
        engine.volume = 0
        let h = try RecoveryHarness(engineOverride: engine)
        defer { engine.stop() }
        await h.resolver.usePlaybackFile(url)
        try await h.play(["a", "b", "c"])
        try await h.waitUntil { h.state.position > 1 }
        for target in [4.5, 1.0, 4.0] { await h.player.seek(to: target) }
        try await Task.sleep(for: .milliseconds(700))
        try await h.player.skipToNext()
        try await h.waitUntil { h.state.currentTrack?.id == "b" && h.state.position > 0.1 }
        #expect(h.state.currentIndex == 1)
        #expect(h.state.position < 1.5)
        #expect(abs(h.state.duration - 6) < 0.15)
        // Both b and c must have been queued before exercising Pause/seek/Resume on b.
        try await h.waitUntil {
            h.report.components(separatedBy: "transition-prepared=native-queue").count >= 3
        }
        try await h.waitUntil { h.state.waitingReason == nil }
        await h.player.pause()
        await h.player.seek(to: 0)
        #expect(h.state.playbackState == .paused)
        #expect(h.state.position < 0.5)
        await h.player.resume()
        // Leave room in the six-second wait for EOF and the next 500-ms UI progress tick.
        try await h.waitUntil { h.state.position > 1 }
        try await h.waitUntil { h.state.currentTrack?.id == "c" && h.state.position > 0.2 }
        #expect(h.state.currentIndex == 2)
        #expect(h.state.queue.map(\.id) == ["a", "b", "c"])
        #expect(h.state.position < 1.5)
        #expect(h.state.waitingReason == nil)
        await h.player.stop()
    }

    @Test(arguments: [0.0, 1.0])
    func playingPreloadedTrackClearsLoading(crossfadeDuration: Double) async throws {
        try AVAudioSession.sharedInstance().setCategory(.playback)
        try AVAudioSession.sharedInstance().setActive(true)
        let url = try #require(Bundle(for: RecoveryAudioFixtureBundle.self).url(
            forResource: "stream-aac.m4a", withExtension: nil
        ))
        let engine = AudioStreamingEngine()
        engine.volume = 0
        let h = try RecoveryHarness(engineOverride: engine, crossfadeDuration: crossfadeDuration)
        defer { engine.stop() }
        await h.resolver.usePlaybackFile(url)
        try await h.play(["a", "b"])
        try await h.waitUntil { h.state.position > 1 }
        #expect(h.state.waitingReason == nil)
        try await h.waitUntil { h.state.currentTrack?.id == "b" && h.state.position > 0.2 }
        // Wait past the presentation debounce: a lingering loading reason must not become visible.
        try await Task.sleep(for: .milliseconds(850))
        #expect(h.state.playbackState == .playing)
        #expect(h.state.position > 0.5)
        #expect(h.state.waitingReason == nil)
        #expect(h.state.playbackStatusMessage == nil)
        await h.player.stop()
    }
}

private final class RecoveryAudioFixtureBundle: NSObject {}

@Suite("Playback duration follows the decoded source", .serialized)
@MainActor
struct PlaybackDurationIntegrationTests {
    @Test(arguments: [117.25, 122.4, 120.25])
    func refinesCatalogDurationInBothDirections(measuredDuration: Double) async throws {
        let h = try RecoveryHarness()
        try await h.play(["a"])
        h.engine.startAdvancing()
        await h.player.handleEngineState(.playing, playbackToken: h.engine.token)
        h.engine.duration = measuredDuration
        try await h.waitUntil { abs(h.state.duration - measuredDuration) < 0.001 }
        #expect(h.state.currentTrack?.duration == 120)
        #expect(h.state.position < measuredDuration)
        await h.player.stop()
    }

    @Test func canCorrectAnEarlierOverestimateWithoutLosingTheDurationDuringBuffering() async throws {
        let h = try RecoveryHarness()
        try await h.play(["a"])
        h.engine.startAdvancing()
        await h.player.handleEngineState(.playing, playbackToken: h.engine.token)
        h.engine.duration = 122.5
        try await h.waitUntil { h.state.duration == 122.5 }
        h.engine.duration = 119.75
        try await h.waitUntil { h.state.duration == 119.75 }
        h.engine.duration = 0
        try await Task.sleep(for: .milliseconds(600))
        #expect(h.state.duration == 119.75)
        h.engine.duration = .nan
        try await Task.sleep(for: .milliseconds(600))
        #expect(h.state.duration == 119.75)
        await h.player.stop()
    }
}
