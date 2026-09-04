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
    func startAdvancing() { storage.withLock { $0.playingSince = Date() } }
    func pause() { storage.withLock { $0.playingSince = nil } }
    func resume() {}
    func stop() { storage.withLock { $0.stops += 1; $0.active = false; $0.playingSince = nil } }
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

private actor RecoveryTestResolver: MediaResolverProtocol {
    var missingIDs: Set<String> = []
    var blockAvailability = false
    var availabilityCalls = 0
    private var pending: CheckedContinuation<MediaAvailability, Never>?
    func configure(missing: Set<String> = [], block: Bool = false) {
        missingIDs = missing
        blockAvailability = block
    }
    func resolve(songId: String, serverId: UUID) async throws -> MediaSource {
        .stream(URL(string: "https://playback.invalid/stream")!, customHeaders: [:])
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
    let resolver = RecoveryTestResolver()
    let diagnostics = PlaybackDiagnostics(capacity: 500)
    let defaults = UserDefaults(suiteName: "playback-recovery.\(UUID())")!

    init(startupGrace: Duration = .milliseconds(600)) throws {
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
        try #require(await condition())
    }
}

@Suite("Player recovery integration", .serialized)
@MainActor
struct PlayerRecoveryIntegrationTests {
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
}
