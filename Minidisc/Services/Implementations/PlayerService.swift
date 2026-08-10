import Foundation
import SwiftSonic
import OSLog
import Synchronization

import AVFAudio

/// A value-only snapshot of an AVAudioSession interruption.
///
/// `Notification` and its `[AnyHashable: Any]` payload are not `Sendable`. Decode the two values
/// PlayerService needs on NotificationCenter's delivery queue, then cross the actor boundary with
/// this enum instead of the Foundation notification.
private nonisolated enum AudioSessionInterruptionEvent: Sendable {
    case began(routeDisconnected: Bool)
    case ended(shouldResume: Bool)

    init?(notification: Notification) {
        guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return nil }

        switch type {
        case .began:
            let reason = (notification.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionReason.init(rawValue:))
            self = .began(routeDisconnected: reason == .routeDisconnected)

        case .ended:
            let options = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map(AVAudioSession.InterruptionOptions.init(rawValue:))
            self = .ended(shouldResume: options?.contains(.shouldResume) == true)

        @unknown default:
            return nil
        }
    }
}

/// Value-only route information extracted on NotificationCenter's delivery queue.
/// `AVAudioSessionPortDescription` itself must not cross into the PlayerService actor.
private nonisolated struct AudioRouteOutputSnapshot: Sendable, Equatable {
    let uid: String
    let portType: AVAudioSession.Port
}

nonisolated enum NetworkPlaybackRecoveryAction: Equatable, Sendable {
    /// No current finite network stream is affected.
    case none
    /// Keep playing buffered audio, but rebuild the item on the next explicit resume.
    case reloadOnResume
    /// The stream was expected to be active; a stalled/error callback may rebuild it automatically.
    case armAutomaticRecovery
}

nonisolated enum NetworkPlaybackProgressValidationOutcome: Equatable, Sendable {
    case validated
    case retry
    case deferToEndOfTrack
}

/// Bounds automatic stream rebuilds without permanently wedging recovery after one early failure.
/// A new track, network-path generation, or explicit Play starts with a fresh budget.
nonisolated struct PlaybackNetworkRecoveryAttemptBudget: Sendable {
    private struct Key: Equatable, Sendable {
        let trackID: String
        let pathGeneration: UInt64
    }

    static let maximumAttempts = 3

    private var key: Key?
    private(set) var attempts = 0

    func canAttempt(trackID: String, pathGeneration: UInt64) -> Bool {
        key != Key(trackID: trackID, pathGeneration: pathGeneration)
            || attempts < Self.maximumAttempts
    }

    mutating func beginAttempt(trackID: String, pathGeneration: UInt64) -> Int? {
        let requestedKey = Key(trackID: trackID, pathGeneration: pathGeneration)
        if key != requestedKey {
            key = requestedKey
            attempts = 0
        }
        guard attempts < Self.maximumAttempts else { return nil }
        attempts += 1
        return attempts
    }

    mutating func reset() {
        key = nil
        attempts = 0
    }
}

actor PlayerService: PlayerServiceProtocol {
    private struct PendingSystemResume {
        let trackID: String
        let playbackGeneration: UInt64
        let transportIntentGeneration: UInt64
        let startedAt: Date
        var requiresPersonalRoute: Bool
        var expectedPersonalRouteUIDs: Set<String>
        var expectedPersonalPortTypes: Set<AVAudioSession.Port>
    }

    nonisolated let state: PlayerState

    private let mediaResolver: any MediaResolverProtocol
    private let serverService: any ServerServiceProtocol
    private let sessionService: PlaybackSessionService
    private let artworkImageCache: ArtworkImageCache
    private let libraryService: any LibraryServiceProtocol
    private let audioStreamCache: any AudioStreamCacheProtocol
    private let downloadService: any DownloadServiceProtocol
    private let cacheSettings: CacheSettings
    private let replayGainSettings: ReplayGainSettings
    private let crossfadeSettings: CrossfadeSettings
    private var crossfadeConfig = CrossfadeConfig(duration: 0, disableForGapless: true)
    private var nowPlayingService: (any NowPlayingServiceProtocol)?
    private let toastService: ToastService
    private let statsService: StatsService
    private let listenBrainzService: ListenBrainzService

    private let engine: AudioEngine
    private let engineBridge: AudioEngineBridge
    private var progressTask: Task<Void, Never>?
    private var pendingRestoreInfo: (seekTime: Double, pause: Bool)?
    private var currentSource: MediaSource?
    private var liveStreamStallTask: Task<Void, Never>?

    private var audioSessionConfigured = false
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var sessionActivationRetryTask: Task<Void, Never>?
    private var isAudioSessionInterrupted = false
    /// Keeps user playback intent distinct from a temporary iOS suspension. It is generation-bound,
    /// so a later user pause, stop, skip or Play always wins over an automatic resume.
    private var pendingSystemResume: PendingSystemResume?
    private nonisolated static let personalRouteReconnectGrace: TimeInterval = 10

    private var endOfTrackEventsInProgress: Set<AudioEnginePlaybackToken> = []
    /// Makes resume restart at track zero after the queue completed.
    private var stoppedAtEndOfQueue = false
    private var isRestoringSession = false
    private var restorePauseTask: Task<Void, Never>?
    private var isMutedForRestore = false
    /// Uses 0.7 when no volume has ever been persisted.
    nonisolated var restoredVolume: Float {
        guard UserDefaults.standard.object(forKey: "minidisc.lastVolume") != nil else { return 0.7 }
        return Float(UserDefaults.standard.double(forKey: "minidisc.lastVolume"))
    }
    private var positionSaveTask: Task<Void, Never>?
    /// Last elapsed position sent to the system Now Playing center. Position updates are intentionally
    /// throttled: the progress UI remains at 2 Hz, while lock-screen metadata only needs 1 Hz.
    private var lastNowPlayingPushElapsed: TimeInterval?
    private var subsonicPlayingNowTask: Task<Void, Never>?
    private var playingNowTask: Task<Void, Never>?
    private var cacheDownloadTask: Task<Void, Never>?
    private let cacheSession: URLSession
    private var prefetchScheduled = false
    /// Invalidates a preload resolution already suspended in MediaResolver when its context changes.
    private var prefetchGeneration: UInt64 = 0
    /// Latest coherent path observed from NetworkMonitor. Generation zero is the launch baseline.
    private var latestNetworkPathEvent: NetworkPathEvent = .initial
    /// Track-specific marker: a Bool could accidentally survive a skip and rebuild the wrong item.
    private var networkReloadRequiredTrackID: String?
    /// A rebuilt item is not trusted on its first `.playing`: Wi-Fi can be `satisfied` before the
    /// server is actually reachable. The marker clears only after its playhead advances post-seek.
    private var networkRecoveryValidationToken: AudioEnginePlaybackToken?
    private var networkRecoveryValidationTask: Task<Void, Never>?
    private var networkRecoveryValidationGeneration: UInt64 = 0
    private var networkRecoveryTask: Task<Void, Never>?
    private var networkRecoveryTaskGeneration: UInt64 = 0
    /// Automatic retries are bounded per track/path. Manual Play resets the budget and remains
    /// available even after all background attempts were consumed.
    private var networkRecoveryAttemptBudget = PlaybackNetworkRecoveryAttemptBudget()
    /// Orders user requests that must build a queue before calling `play`.
    /// It is separate from `playbackGeneration`, so a failed Smart Shuffle or
    /// Instant Mix lookup does not invalidate the playback already in progress.
    private var queueBuildGeneration: UInt64 = 0
    private var playbackGeneration: UInt64 = 0
    /// Orders transport commands independently from the currently loaded track. Pause/resume can
    /// therefore invalidate a slow start/restore without discarding track-scoped cache work.
    private var transportIntentGeneration: UInt64 = 0
    private struct ActiveEnginePlayback {
        let token: AudioEnginePlaybackToken
        let playbackGeneration: UInt64
        let transportIntentGeneration: UInt64
    }
    private var activeEnginePlayback: ActiveEnginePlayback?
    /// Changes only when the queue session is replaced (not on an ordinary skip).
    private var queueGeneration: UInt64 = 0
    /// Serializes the state/engine commit phase while still allowing a newer play
    /// intent to invalidate an older resolver in flight.
    private var transitionCommitInProgress = false
    private var transitionCommitWaiters: [CheckedContinuation<Void, Never>] = []
    private var seekGeneration: UInt64 = 0
    private var durationMismatchLoggedTrackID: String?
    private var originalQueueOrder: [DisplayableSong]?
    private var instantMixTask: Task<Void, Never>?
    private var autoExtendFetchTask: Task<Void, Never>?
    /// Distinguishes an in-flight fetch from a later replacement. A cancelled server request may
    /// still return, so task cancellation alone is not enough to protect the replacement's handle.
    private var autoExtendFetchGeneration: UInt64 = 0
    private nonisolated static let autoExtendUserDefaultsKey = "minidisc.player.autoExtendEnabled"

    private var playbackProgressTracker = PlaybackProgressTracker()
    private var wasTrackCompletedNaturally: Bool = false

    init(
        state: PlayerState,
        mediaResolver: any MediaResolverProtocol,
        serverService: any ServerServiceProtocol,
        sessionService: PlaybackSessionService,
        artworkImageCache: ArtworkImageCache,
        libraryService: any LibraryServiceProtocol,
        audioStreamCache: any AudioStreamCacheProtocol,
        downloadService: any DownloadServiceProtocol,
        cacheSettings: CacheSettings,
        replayGainSettings: ReplayGainSettings,
        crossfadeSettings: CrossfadeSettings,
        initialCrossfadeConfig: CrossfadeConfig,
        toastService: ToastService,
        statsService: StatsService,
        listenBrainzService: ListenBrainzService,
        engine: AudioEngine
    ) {
        self.state = state
        self.mediaResolver = mediaResolver
        self.serverService = serverService
        self.sessionService = sessionService
        self.artworkImageCache = artworkImageCache
        self.libraryService = libraryService
        self.audioStreamCache = audioStreamCache
        self.downloadService = downloadService
        self.cacheSettings = cacheSettings
        self.replayGainSettings = replayGainSettings
        self.crossfadeSettings = crossfadeSettings
        self.crossfadeConfig = initialCrossfadeConfig
        self.toastService = toastService
        self.statsService = statsService
        self.listenBrainzService = listenBrainzService
        let cacheConfig = URLSessionConfiguration.default
        cacheConfig.timeoutIntervalForRequest = 30
        cacheConfig.timeoutIntervalForResource = 300
        cacheConfig.networkServiceType = .background
        self.cacheSession = URLSession(configuration: cacheConfig)

        self.engine = engine
        let bridge = AudioEngineBridge()
        self.engineBridge = bridge
        bridge.connect(to: self)
        engine.delegate = bridge
    }

    func setNowPlayingService(_ service: any NowPlayingServiceProtocol) {
        nowPlayingService = service
    }

    private func waitForTransitionCommit() async {
        while transitionCommitInProgress {
            await withCheckedContinuation { continuation in
                transitionCommitWaiters.append(continuation)
            }
        }
    }

    private func beginTransitionCommit() {
        precondition(!transitionCommitInProgress)
        transitionCommitInProgress = true
    }

    private func endTransitionCommit() {
        guard transitionCommitInProgress else { return }
        transitionCommitInProgress = false
        let waiters = transitionCommitWaiters
        transitionCommitWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func isCurrentPlaybackIntent(
        playbackGeneration: UInt64,
        transportIntentGeneration: UInt64
    ) -> Bool {
        playbackGeneration == self.playbackGeneration
            && transportIntentGeneration == self.transportIntentGeneration
            && !Task.isCancelled
    }

    private func registerActiveEnginePlayback(
        _ token: AudioEnginePlaybackToken,
        playbackGeneration: UInt64,
        transportIntentGeneration: UInt64
    ) {
        activeEnginePlayback = ActiveEnginePlayback(
            token: token,
            playbackGeneration: playbackGeneration,
            transportIntentGeneration: transportIntentGeneration
        )
    }

    private func isCurrentEngineEvent(_ token: AudioEnginePlaybackToken) -> Bool {
        guard let activeEnginePlayback else { return false }
        return activeEnginePlayback.token == token
            && activeEnginePlayback.playbackGeneration == playbackGeneration
            && activeEnginePlayback.transportIntentGeneration == transportIntentGeneration
    }

    nonisolated static func networkRecoveryAction(
        sourceIsRemoteStream: Bool,
        isOnline: Bool,
        playbackState: PlaybackState
    ) -> NetworkPlaybackRecoveryAction {
        guard sourceIsRemoteStream else { return .none }
        guard isOnline else { return .reloadOnResume }
        switch playbackState {
        case .playing, .error:
            return .armAutomaticRecovery
        case .idle, .loading, .paused:
            return .reloadOnResume
        }
    }

    nonisolated static func shouldReassertPlaybackOnOnlinePath(
        sourceIsRemoteStream: Bool,
        isOnline: Bool,
        playbackState: PlaybackState,
        position: TimeInterval,
        duration: TimeInterval
    ) -> Bool {
        guard sourceIsRemoteStream, isOnline else { return false }
        guard playbackState == .playing else { return false }
        return duration <= 0 || position < duration - 1.5
    }

    nonisolated static func networkProgressValidationOutcome(
        baseline: TimeInterval,
        current: TimeInterval,
        duration: TimeInterval
    ) -> NetworkPlaybackProgressValidationOutcome {
        if current > baseline + 0.1 { return .validated }
        if duration > 0, current >= duration - 1.5 { return .deferToEndOfTrack }
        return .retry
    }

    private var currentSourceIsRemoteStream: Bool {
        if case .stream = currentSource { return true }
        return false
    }

    // MARK: - Play

    func play(tracks: [DisplayableSong], startIndex: Int) async throws {
        guard tracks.indices.contains(startIndex) else { return }
        queueBuildGeneration &+= 1
        stoppedAtEndOfQueue = false
        playbackGeneration &+= 1
        transportIntentGeneration &+= 1
        let generation = playbackGeneration
        let transportGeneration = transportIntentGeneration
        cancelNetworkRecoveryProbe()
        cancelNetworkRecoveryValidation()
        pendingSystemResume = nil
        let previousEnginePlayback = activeEnginePlayback
        defer {
            // Resolution can fail before the engine is replaced. Keep the still-audible item eligible
            // for callbacks under the newly claimed intent; otherwise one failed Play request would
            // permanently suppress its eventual EOF/error events.
            if generation == playbackGeneration,
               transportGeneration == transportIntentGeneration,
               let previousEnginePlayback,
               activeEnginePlayback?.token == previousEnginePlayback.token,
               activeEnginePlayback?.playbackGeneration != generation {
                activeEnginePlayback = ActiveEnginePlayback(
                    token: previousEnginePlayback.token,
                    playbackGeneration: generation,
                    transportIntentGeneration: transportGeneration
                )
            }
        }
        isRestoringSession = false
        cancelPendingInstantMix()
        cancelPendingPrefetch()

        // Reset shuffle only when starting a genuinely new queue, not on internal skips
        // (skipToNext/skipToPrevious pass state.queue unchanged, so IDs match).
        let currentQueueIds = await MainActor.run { state.queue.map(\.id) }
        guard isCurrentPlaybackIntent(
            playbackGeneration: generation,
            transportIntentGeneration: transportGeneration
        ) else { return }
        let isNewQueue = tracks.map(\.id) != currentQueueIds
        if isNewQueue {
            autoExtendFetchTask?.cancel()
            autoExtendFetchTask = nil
        }

        let activeServerID = await MainActor.run { serverService.state.activeServer?.id }
        guard isCurrentPlaybackIntent(
            playbackGeneration: generation,
            transportIntentGeneration: transportGeneration
        ) else { return }
        guard let serverId = activeServerID else {
            await MainActor.run { state.playbackState = .error(.serverNotConfigured) }
            throw MinidiscError.serverNotConfigured
        }

        let previousPlaybackState = await MainActor.run { state.playbackState }
        guard isCurrentPlaybackIntent(
            playbackGeneration: generation,
            transportIntentGeneration: transportGeneration
        ) else { return }
        await MainActor.run { state.playbackState = .loading }
        guard isCurrentPlaybackIntent(
            playbackGeneration: generation,
            transportIntentGeneration: transportGeneration
        ) else { return }

        let song = tracks[startIndex]
        let source: MediaSource
        do {
            source = try await mediaResolver.resolve(songId: song.id, serverId: serverId)
        } catch let e as MinidiscError {
            guard isCurrentPlaybackIntent(
                playbackGeneration: generation,
                transportIntentGeneration: transportGeneration
            ) else { return }
            await MainActor.run { state.playbackState = previousPlaybackState }
            throw e
        } catch {
            guard isCurrentPlaybackIntent(
                playbackGeneration: generation,
                transportIntentGeneration: transportGeneration
            ) else { return }
            await MainActor.run { state.playbackState = previousPlaybackState }
            throw error
        }
        guard isCurrentPlaybackIntent(
            playbackGeneration: generation,
            transportIntentGeneration: transportGeneration
        ) else {
            Logger.player.debug("[TRANSITION] discarded stale resolved source for '\(song.id, privacy: .public)'")
            return
        }

        await startPlayback(
            tracks: tracks,
            startIndex: startIndex,
            song: song,
            source: source,
            serverId: serverId,
            isNewQueue: isNewQueue,
            generation: generation,
            transportGeneration: transportGeneration
        )
    }

    private func startPlayback(
        tracks: [DisplayableSong],
        startIndex: Int,
        song: DisplayableSong,
        source: MediaSource,
        serverId: UUID,
        isNewQueue: Bool,
        generation: UInt64,
        transportGeneration: UInt64
    ) async {
        await waitForTransitionCommit()
        guard isCurrentPlaybackIntent(
            playbackGeneration: generation,
            transportIntentGeneration: transportGeneration
        ) else { return }
        beginTransitionCommit()
        var ownsTransitionCommit = true
        defer {
            if ownsTransitionCommit {
                endTransitionCommit()
            }
        }

        await recordCurrentTrackPlayback(trigger: wasTrackCompletedNaturally ? "track_completed" : "user_skipped")
        guard isCurrentPlaybackIntent(
            playbackGeneration: generation,
            transportIntentGeneration: transportGeneration
        ) else { return }
        wasTrackCompletedNaturally = false
        playbackProgressTracker.startTrack()

        cancelPendingScrobble()
        cancelPendingCacheDownload()
        cancelPendingPrefetch()

        if isNewQueue {
            originalQueueOrder = nil
            queueGeneration &+= 1
        }
        let committedQueueGeneration = queueGeneration
        await MainActor.run {
            if state.currentRadio != nil {
                Logger.player.debug("Ending live stream session — switching to queue playback")
            }
            state.queue = tracks
            state.queueGeneration = committedQueueGeneration
            state.currentIndex = startIndex
            state.currentRadio = nil
            state.playbackState = .loading
            if isNewQueue {
                state.isShuffled = false
                state.originalQueueEndIndex = nil
                if state.isSmartShuffleActive {
                    state.isSmartShuffleActive = false
                    Logger.player.debug("Ending Smart Shuffle session — starting new explicit queue")
                }
            }
        }
        guard isCurrentPlaybackIntent(
            playbackGeneration: generation,
            transportIntentGeneration: transportGeneration
        ) else { return }

        let config = await MainActor.run { replayGainSettings.config }
        guard isCurrentPlaybackIntent(
            playbackGeneration: generation,
            transportIntentGeneration: transportGeneration
        ) else { return }
        let replayGainDB = ReplayGainService.gainDB(track: song, config: config)
        engine.applyReplayGain(dB: replayGainDB)
        logReplayGain(track: song, config: config, appliedDB: replayGainDB, context: "start")

        let songId = song.id
        durationMismatchLoggedTrackID = nil
        Logger.player.info("[TRANSITION] advancing to '\(song.title, privacy: .public)' (id=\(song.id, privacy: .public)) — starting playback")

        stopProgressTimer()
        stopPositionSaveTimer()
        liveStreamStallTask?.cancel()
        liveStreamStallTask = nil
        currentSource = source
        cancelNetworkRecoveryProbe()
        cancelNetworkRecoveryValidation()
        networkReloadRequiredTrackID = nil
        lastNowPlayingPushElapsed = nil
        networkRecoveryAttemptBudget.reset()
        pendingRestoreInfo = nil
        // Starting a new track can interrupt a muted parking play (end-of-queue rewind)
        // without going through resume()/stop() — cancel the deferred pause and unmute,
        // otherwise the new track would start silent or get paused 150 ms in.
        restorePauseTask?.cancel()
        restorePauseTask = nil
        if isMutedForRestore {
            engine.volume = restoredVolume
            isMutedForRestore = false
        }

        configureAudioSessionIfNeeded()

        let playbackToken = engine.play(
            trackID: song.id,
            url: source.url,
            headers: source.customHeaders
        )
        registerActiveEnginePlayback(
            playbackToken,
            playbackGeneration: generation,
            transportIntentGeneration: transportGeneration
        )

        let duration = song.duration
        await MainActor.run {
            state.currentTrack = song
            state.duration = duration
            state.position = 0
            state.playbackState = .playing
            state.isPlaybackAvailable = true
        }
        guard generation == playbackGeneration,
              transportGeneration == transportIntentGeneration else { return }
        // Give the engine the authoritative length — its own estimate drifts on transcoded streams,
        // which would arm the crossfade window at the wrong moment.
        engine.setTrackDuration(Double(duration))

        startProgressTimer()

        // The engine + observable state now form one committed transition. Artwork, credentials,
        // persistence and cache setup may suspend on network or disk and must not block a newer
        // pause/stop/play intent behind the transition gate.
        endTransitionCommit()
        ownsTransitionCommit = false

        guard isCurrentPlaybackIntent(
            playbackGeneration: generation,
            transportIntentGeneration: transportGeneration
        ) else { return }
        subsonicPlayingNowTask = Task { [libraryService] in
            await libraryService.scrobble(songId: songId, submission: false)
        }
        playingNowTask = Task { [listenBrainzService, weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else { return }
            let stillActive = await MainActor.run {
                self.state.playbackState == .playing && self.state.currentTrack?.id == song.id
            }
            guard stillActive else { return }
            await listenBrainzService.notifyTrackStarted(song: song)
        }

        if case .stream(let streamURL, let customHeaders) = source {
            let (allowCellular, cacheFormat) = await MainActor.run {
                (cacheSettings.cacheOverCellular, cacheSettings.cacheFormat)
            }
            guard isCurrentPlaybackIntent(
                playbackGeneration: generation,
                transportIntentGeneration: transportGeneration
            ) else { return }

            let cacheStreamURL: URL?
            if cacheFormat == .matchStream {
                cacheStreamURL = streamURL
            } else {
                cacheStreamURL = (try? await serverService.makeSwiftSonicClient())?.streamURL(
                    id: songId,
                    maxBitRate: cacheFormat.subsonicMaxBitRate,
                    format: cacheFormat.subsonicFormat
                )
                guard isCurrentPlaybackIntent(
                    playbackGeneration: generation,
                    transportIntentGeneration: transportGeneration
                ) else { return }
            }

            if let cacheStreamURL {
                cacheDownloadTask = Task { [weak self] in
                    await self?.cacheStreamAfterDelay(
                        songId: songId,
                        serverId: serverId,
                        streamURL: cacheStreamURL,
                        customHeaders: customHeaders,
                        allowCellular: allowCellular,
                        generation: generation
                    )
                }
            } else {
                Logger.player.debug("Cache: no URL for '\(songId, privacy: .public)' in \(cacheFormat.rawValue) — skipping")
            }
        }

        let artworkURL = await resolveArtworkURL(for: song)
        guard isCurrentPlaybackIntent(
            playbackGeneration: generation,
            transportIntentGeneration: transportGeneration
        ) else { return }
        let artworkHeaders: [String: String]
        do {
            artworkHeaders = try await serverService.activeCredentials().customHeaders
        } catch {
            Logger.player.warning("[CREDENTIALS] activeCredentials failed, using empty headers: \(error, privacy: .public)")
            artworkHeaders = [:]
        }
        guard isCurrentPlaybackIntent(
            playbackGeneration: generation,
            transportIntentGeneration: transportGeneration
        ) else { return }
        let snapshot = NowPlayingSnapshot(
            title: song.title,
            artist: song.artist,
            album: song.albumName,
            duration: duration,
            position: 0,
            playbackRate: 1.0,
            artworkURL: artworkURL,
            artworkHeaders: artworkHeaders,
            coverArtId: song.coverArtId,
            isLiveStream: false,
            radioStationName: nil,
            songId: song.id
        )
        await nowPlayingService?.update(with: snapshot)
        guard isCurrentPlaybackIntent(
            playbackGeneration: generation,
            transportIntentGeneration: transportGeneration
        ) else { return }
        await saveSession()
        guard isCurrentPlaybackIntent(
            playbackGeneration: generation,
            transportIntentGeneration: transportGeneration
        ) else { return }
        startPositionSaveTimer()
        preloadNextTrackArtwork()
        await evaluateAutoExtend()
    }

    // MARK: - Live Stream

    func playRadio(_ station: InternetRadioStation) async throws {
        queueBuildGeneration &+= 1
        playbackGeneration &+= 1
        transportIntentGeneration &+= 1
        let generation = playbackGeneration
        let transportGeneration = transportIntentGeneration
        cancelNetworkRecoveryProbe()
        cancelNetworkRecoveryValidation()
        pendingSystemResume = nil
        networkReloadRequiredTrackID = nil
        lastNowPlayingPushElapsed = nil
        networkRecoveryAttemptBudget.reset()
        let previousEnginePlayback = activeEnginePlayback
        defer {
            if generation == playbackGeneration,
               transportGeneration == transportIntentGeneration,
               let previousEnginePlayback,
               activeEnginePlayback?.token == previousEnginePlayback.token,
               activeEnginePlayback?.playbackGeneration != generation {
                activeEnginePlayback = ActiveEnginePlayback(
                    token: previousEnginePlayback.token,
                    playbackGeneration: generation,
                    transportIntentGeneration: transportGeneration
                )
            }
        }
        isRestoringSession = false
        cancelPendingPrefetch()
        let source = try await mediaResolver.resolveRadio(station)
        guard isCurrentPlaybackIntent(
            playbackGeneration: generation,
            transportIntentGeneration: transportGeneration
        ) else { return }

        let codecResult = await checkCodecSupport(url: source.url, headers: source.customHeaders)
        guard isCurrentPlaybackIntent(
            playbackGeneration: generation,
            transportIntentGeneration: transportGeneration
        ) else { return }
        if case .unsupported(let contentType) = codecResult {
            Logger.player.warning("[RADIO-CODEC] rejected stream, content-type=\(contentType, privacy: .public)")
            await MainActor.run {
                toastService.show(
                    "This radio uses an unsupported audio format. Minidisc can play MP3 and AAC live streams currently.",
                    style: .error,
                    duration: 5.0
                )
            }
            return
        }

        await waitForTransitionCommit()
        guard isCurrentPlaybackIntent(
            playbackGeneration: generation,
            transportIntentGeneration: transportGeneration
        ) else { return }
        beginTransitionCommit()
        var ownsTransitionCommit = true
        defer {
            if ownsTransitionCommit {
                endTransitionCommit()
            }
        }

        await recordCurrentTrackPlayback(trigger: "radio_started")
        guard isCurrentPlaybackIntent(
            playbackGeneration: generation,
            transportIntentGeneration: transportGeneration
        ) else { return }
        playbackProgressTracker.reset()
        cancelPendingScrobble()
        cancelPendingCacheDownload()
        cancelPendingPrefetch()
        cancelPendingInstantMix()
        autoExtendFetchTask?.cancel()
        autoExtendFetchTask = nil
        engine.cancelPreload()
        engine.applyReplayGain(dB: 0)
        stopProgressTimer()
        stopPositionSaveTimer()
        liveStreamStallTask?.cancel()
        liveStreamStallTask = nil
        currentSource = source
        cancelNetworkRecoveryProbe()
        cancelNetworkRecoveryValidation()
        networkReloadRequiredTrackID = nil
        pendingRestoreInfo = nil
        // Same recovery as startPlayback(): a radio start can interrupt a muted
        // parking play — cancel the deferred pause and unmute before playing.
        restorePauseTask?.cancel()
        restorePauseTask = nil
        if isMutedForRestore {
            engine.volume = restoredVolume
            isMutedForRestore = false
        }

        configureAudioSessionIfNeeded()

        queueGeneration &+= 1
        let radioQueueGeneration = queueGeneration
        await MainActor.run {
            state.queueGeneration = radioQueueGeneration
            state.currentTrack = nil
            state.currentRadio = station
            state.isSmartShuffleActive = false
            state.originalQueueEndIndex = nil
            state.playbackState = .loading
            state.position = 0
            state.duration = 0
        }
        guard isCurrentPlaybackIntent(
            playbackGeneration: generation,
            transportIntentGeneration: transportGeneration
        ) else { return }

        let playbackToken = engine.play(
            trackID: "radio:\(station.id)",
            url: source.url,
            headers: source.customHeaders
        )
        registerActiveEnginePlayback(
            playbackToken,
            playbackGeneration: generation,
            transportIntentGeneration: transportGeneration
        )

        await MainActor.run {
            state.playbackState = .playing
            state.isPlaybackAvailable = true
        }
        guard generation == playbackGeneration,
              transportGeneration == transportIntentGeneration else { return }

        startProgressTimer()
        startLiveStreamStallMonitor(stationName: station.name)

        endTransitionCommit()
        ownsTransitionCommit = false

        let artworkHeaders: [String: String]
        do {
            artworkHeaders = try await serverService.activeCredentials().customHeaders
        } catch {
            Logger.player.warning("[CREDENTIALS] activeCredentials failed, using empty headers: \(error, privacy: .public)")
            artworkHeaders = [:]
        }
        guard isCurrentPlaybackIntent(
            playbackGeneration: generation,
            transportIntentGeneration: transportGeneration
        ) else { return }
        await nowPlayingService?.update(with: NowPlayingSnapshot(
            title: station.name,
            artist: "Live Radio",
            album: nil,
            duration: 0,
            position: 0,
            playbackRate: 1.0,
            artworkURL: nil,
            artworkHeaders: artworkHeaders,
            coverArtId: station.coverArt,
            isLiveStream: true,
            radioStationName: station.name,
            songId: nil
        ))
        guard isCurrentPlaybackIntent(
            playbackGeneration: generation,
            transportIntentGeneration: transportGeneration
        ) else { return }

        startPositionSaveTimer()
        Logger.player.info("Started live stream radio '\(station.name, privacy: .public)'")
    }

    // MARK: - Live Stream Codec Check & Failsafe

    private nonisolated enum LiveStreamCodecResult {
        case supported
        case unsupported(contentType: String)
        case ambiguous
    }

    private func checkCodecSupport(url: URL, headers: [String: String]) async -> LiveStreamCodecResult {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringCacheData, timeoutInterval: 2.0)
        request.httpMethod = "HEAD"
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse else {
            Logger.player.debug("[RADIO-CODEC] HEAD request failed or timed out — letting player try")
            return .ambiguous
        }
        let rawType = (httpResponse.allHeaderFields["Content-Type"] as? String ?? "").lowercased()
        let contentType = rawType.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces) ?? ""

        let whitelist: Set<String> = ["audio/mpeg", "audio/mp4", "audio/aac", "audio/x-aac", "audio/aacp"]
        let blacklist: Set<String> = ["audio/flac", "audio/x-flac", "audio/opus", "audio/ogg", "audio/vorbis"]

        if whitelist.contains(contentType) {
            Logger.player.debug("[RADIO-CODEC] content-type=\(contentType, privacy: .public) → supported")
            return .supported
        }
        if blacklist.contains(contentType) {
            return .unsupported(contentType: contentType)
        }
        Logger.player.debug("[RADIO-CODEC] content-type=\(contentType.isEmpty ? "(empty)" : contentType, privacy: .public) → ambiguous, letting player try")
        return .ambiguous
    }

    private func startLiveStreamStallMonitor(stationName: String) {
        liveStreamStallTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            let (isStillLive, position) = await MainActor.run { (self.state.isLiveStream, self.state.position) }
            guard isStillLive, position < 1.0 else { return }
            await self.handleLiveStreamFailure(stationName: stationName, error: nil)
        }
    }

    private func handleLiveStreamFailure(stationName: String, error: Error?) async {
        let isStillLive = await MainActor.run { state.isLiveStream }
        guard isStillLive else { return }

        Logger.player.error("[RADIO-FAILSAFE] live stream '\(stationName, privacy: .public)' failed: \(error?.localizedDescription ?? "stall timeout", privacy: .public)")

        stopProgressTimer()
        engine.stop()
        activeEnginePlayback = nil

        await MainActor.run {
            state.currentRadio = nil
            state.playbackState = .idle
            toastService.show(
                "Stream unavailable. The radio may be down or use an unsupported format.",
                style: .error,
                duration: 5.0
            )
        }
    }

    // MARK: - Smart Shuffle

    func playSmartShuffle() async throws {
        // Claim the user intent before the potentially slow library query. A later
        // play/stop request must win even if this query completes afterwards.
        queueBuildGeneration &+= 1
        let requestGeneration = queueBuildGeneration
        cancelPendingInstantMix()

        let tracks = try await libraryService.smartShuffleQueue(targetSize: 50)
        try Task.checkCancellation()
        guard requestGeneration == queueBuildGeneration else { return }
        guard !tracks.isEmpty else {
            Logger.player.info("Smart shuffle returned empty — library too small or no downloads offline")
            throw MinidiscError.smartShuffleEmpty
        }

        // play(tracks:) resets isSmartShuffleActive via the new-queue check, so set the flag after.
        let expectedPlayGeneration = playbackGeneration &+ 1
        let expectedBuildGeneration = queueBuildGeneration &+ 1
        try await play(tracks: tracks, startIndex: 0)
        guard expectedPlayGeneration == playbackGeneration,
              expectedBuildGeneration == queueBuildGeneration
        else { return }
        let expectedQueueGeneration = queueGeneration
        let expectedTrackIDs = tracks.map(\.id)
        let didCommit = await MainActor.run {
            guard state.queueGeneration == expectedQueueGeneration,
                  state.queue.map(\.id) == expectedTrackIDs,
                  state.currentTrack?.id == tracks[0].id
            else { return false }
            state.isSmartShuffleActive = true
            return true
        }
        guard didCommit,
              expectedPlayGeneration == playbackGeneration,
              expectedBuildGeneration == queueBuildGeneration
        else { return }

        Logger.player.info("Started Smart Shuffle session with \(tracks.count) tracks")
    }

    // MARK: - Instant Mix

    /// Starts the seed immediately when available and builds the rest in the background.
    func playInstantMix(from seed: InstantMixSeed, startingWith seedTrack: DisplayableSong?) async throws {
        // Like Smart Shuffle, claim before resolving the seed: the result of an
        // older, slower request must never replace a newer playback intent.
        queueBuildGeneration &+= 1
        let requestGeneration = queueBuildGeneration
        cancelPendingInstantMix()

        // `??` cannot host an async right-hand side (autoclosures are not concurrency-aware).
        let resolved: DisplayableSong?
        if let seedTrack {
            resolved = seedTrack
        } else {
            resolved = await starterTrack(for: seed)
        }
        try Task.checkCancellation()
        guard requestGeneration == queueBuildGeneration else { return }
        guard let starter = resolved else {
            try await buildThenPlayInstantMix(
                from: seed,
                requestGeneration: requestGeneration
            )
            return
        }
        let expectedPlayGeneration = playbackGeneration &+ 1
        let expectedBuildGeneration = queueBuildGeneration &+ 1
        try await play(tracks: [starter], startIndex: 0)
        guard expectedPlayGeneration == playbackGeneration,
              expectedBuildGeneration == queueBuildGeneration
        else { return }
        let generation = expectedPlayGeneration
        let expectedQueueGeneration = queueGeneration
        guard await MainActor.run(body: {
            state.queueGeneration == expectedQueueGeneration
                && state.queue.map(\.id) == [starter.id]
                && state.currentTrack?.id == starter.id
        }) else { return }
        guard generation == playbackGeneration,
              expectedBuildGeneration == queueBuildGeneration
        else { return }
        Logger.player.info("[MIX-TIMING] seed '\(starter.id, privacy: .public)' playing immediately — mix building behind it")
        // Auto-extend stays off until the mix lands to avoid a competing background fill.
        instantMixTask = Task { [weak self] in
            guard let self else { return }
            await BackgroundActivity.run("instant-mix") {
                await self.appendInstantMix(
                    from: seed,
                    behind: starter,
                    generation: generation,
                    queueGeneration: expectedQueueGeneration
                )
            }
            await self.instantMixDidFinish(generation: generation)
        }
    }

    private func starterTrack(for seed: InstantMixSeed) async -> DisplayableSong? {
        switch seed {
        case .song:
            return nil
        case .album(let id):
            guard let song = (try? await libraryService.album(id: id))?.song?.first else { return nil }
            return DisplayableSong(from: song)
        case .artist(let id):
            guard let albumId = (try? await libraryService.artist(id: id))?.album?.first?.id,
                  let song = (try? await libraryService.album(id: albumId))?.song?.first
            else { return nil }
            return DisplayableSong(from: song)
        }
    }

    private func appendInstantMix(
        from seed: InstantMixSeed,
        behind seedTrack: DisplayableSong,
        generation: UInt64,
        queueGeneration: UInt64
    ) async {
        do {
            try Task.checkCancellation()
            let tracks = try await libraryService.instantMix(from: seed, count: 100)
            try Task.checkCancellation()
            guard generation == playbackGeneration,
                  queueGeneration == self.queueGeneration else {
                Logger.player.info("[INSTANT-MIX] built mix discarded — playback moved on during the build")
                return
            }
            let fresh = tracks.filter { $0.id != seedTrack.id }
            guard let appendedCount = await commitInstantMix(
                fresh,
                seedTrackID: seedTrack.id,
                generation: generation,
                queueGeneration: queueGeneration
            ) else {
                Logger.player.info("[INSTANT-MIX] built mix discarded — queue was replaced during commit")
                return
            }
            UserDefaults.standard.set(true, forKey: Self.autoExtendUserDefaultsKey)
            await saveSession()
            guard appendedCount > 0 else {
                Logger.player.info("[INSTANT-MIX] no similarity data for seed — continuing with the library-based endless queue")
                await MainActor.run {
                    toastService.show("No Instant Mix data for this track — continuing from your library.", style: .info, duration: 4.0)
                }
                return
            }
            Logger.player.info("[INSTANT-MIX] appended \(appendedCount, privacy: .public) tracks behind the seed (auto-extend on)")
        } catch is CancellationError {
            Logger.player.debug("[INSTANT-MIX] background build cancelled")
        } catch {
            Logger.player.error("[INSTANT-MIX] background build failed: \(error, privacy: .public)")
            await MainActor.run { toastService.showError("Couldn't build the Instant Mix.") }
        }
    }

    private func commitInstantMix(
        _ tracks: [DisplayableSong],
        seedTrackID: String,
        generation: UInt64,
        queueGeneration: UInt64
    ) async -> Int? {
        guard generation == playbackGeneration,
              queueGeneration == self.queueGeneration,
              !Task.isCancelled else { return nil }
        return await MainActor.run {
            guard state.queueGeneration == queueGeneration,
                  state.currentTrack?.id == seedTrackID else { return nil }

            let existingIDs = Set(state.queue.map(\.id))
            let freshTracks = tracks.filter { !existingIDs.contains($0.id) }
            state.repeatMode = .off
            state.isShuffled = false
            state.isAutoExtendEnabled = true
            state.queue.append(contentsOf: freshTracks)
            return freshTracks.count
        }
    }

    private func instantMixDidFinish(generation: UInt64) {
        guard generation == playbackGeneration else { return }
        instantMixTask = nil
    }

    private func cancelPendingInstantMix() {
        instantMixTask?.cancel()
        instantMixTask = nil
    }

    /// Blocking fallback for seeds that do not provide a starter track.
    private func buildThenPlayInstantMix(
        from seed: InstantMixSeed,
        requestGeneration: UInt64
    ) async throws {
        let tStart = Date()
        let tracks = try await libraryService.instantMix(from: seed, count: 100)
        try Task.checkCancellation()
        guard requestGeneration == queueBuildGeneration else { return }
        let buildMs = Int(Date().timeIntervalSince(tStart) * 1000)
        guard !tracks.isEmpty else {
            Logger.player.info("Instant Mix returned empty — no similarity data for seed")
            throw MinidiscError.instantMixEmpty
        }
        let tPlay = Date()
        let expectedPlayGeneration = playbackGeneration &+ 1
        let expectedBuildGeneration = queueBuildGeneration &+ 1
        try await play(tracks: tracks, startIndex: 0)
        guard expectedPlayGeneration == playbackGeneration,
              expectedBuildGeneration == queueBuildGeneration
        else { return }
        let expectedQueueGeneration = queueGeneration
        let expectedTrackIDs = tracks.map(\.id)
        let didCommit = await MainActor.run {
            guard state.queueGeneration == expectedQueueGeneration,
                  state.queue.map(\.id) == expectedTrackIDs,
                  state.currentTrack?.id == tracks[0].id
            else { return false }
            state.repeatMode = .off
            state.isShuffled = false
            state.isAutoExtendEnabled = true
            return true
        }
        guard didCommit,
              expectedPlayGeneration == playbackGeneration,
              expectedBuildGeneration == queueBuildGeneration
        else { return }
        UserDefaults.standard.set(true, forKey: Self.autoExtendUserDefaultsKey)
        Logger.player.info("[MIX-TIMING] end-to-end=\(Int(Date().timeIntervalSince(tStart) * 1000), privacy: .public)ms (build=\(buildMs, privacy: .public)ms, start=\(Int(Date().timeIntervalSince(tPlay) * 1000), privacy: .public)ms)")
        await evaluateAutoExtend()
        guard expectedPlayGeneration == playbackGeneration,
              expectedBuildGeneration == queueBuildGeneration
        else { return }
        Logger.player.info("Started Instant Mix with \(tracks.count) tracks (auto-extend on)")
    }

    func setVolume(_ volume: Float) async {
        let clamped = max(0, min(1, volume))
        engine.volume = clamped
        if clamped > 0 {
            UserDefaults.standard.set(clamped, forKey: "minidisc.lastVolume")
        }
    }

    func replayGainSettingsDidChange() async {
        let (track, config) = await MainActor.run { (state.currentTrack, replayGainSettings.config) }
        let replayGainDB = track.map { ReplayGainService.gainDB(track: $0, config: config) } ?? 0
        engine.applyReplayGain(dB: replayGainDB)
        if let track {
            logReplayGain(track: track, config: config, appliedDB: replayGainDB, context: "settings")
        }
    }

    private func logReplayGain(
        track: DisplayableSong,
        config: ReplayGainConfig,
        appliedDB: Float,
        context: String
    ) {
        let trackGainDescription = track.replayGainTrackGain.map { String(format: "%.2f", $0) } ?? "missing"
        let albumGainDescription = track.replayGainAlbumGain.map { String(format: "%.2f", $0) } ?? "missing"
        let trackPeakDescription = track.replayGainTrackPeak.map { String(format: "%.6f", $0) } ?? "missing"
        let albumPeakDescription = track.replayGainAlbumPeak.map { String(format: "%.6f", $0) } ?? "missing"
        let baseDescription = track.replayGainBaseGain.map { String(format: "%.2f", $0) } ?? "missing"
        let fallbackDescription = track.replayGainFallbackGain.map { String(format: "%.2f", $0) } ?? "missing"
        Logger.player.info(
            "[REPLAYGAIN] context=\(context, privacy: .public) track='\(track.id, privacy: .public)' enabled=\(config.enabled, privacy: .public) mode=\(config.mode.rawValue, privacy: .public) trackGain=\(trackGainDescription, privacy: .public)dB albumGain=\(albumGainDescription, privacy: .public)dB trackPeak=\(trackPeakDescription, privacy: .public) albumPeak=\(albumPeakDescription, privacy: .public) base=\(baseDescription, privacy: .public)dB fallback=\(fallbackDescription, privacy: .public)dB preAmp=\(config.preAmp, format: .fixed(precision: 1))dB applied=\(appliedDB, format: .fixed(precision: 2))dB"
        )
    }

    func crossfadeSettingsDidChange() async {
        crossfadeConfig = await MainActor.run { crossfadeSettings.config }
        Logger.player.info(
            "[CROSSFADE] settings duration=\(self.crossfadeConfig.duration, format: .fixed(precision: 1))s keepAlbumTracksBackToBack=\(self.crossfadeConfig.disableForGapless, privacy: .public) appliesToNextPreload=true"
        )
    }

    func setAutoExtendEnabled(_ enabled: Bool) async {
        if enabled {
            // Clear conflicting modes before enabling auto-extend to avoid an early fetch.
            if await MainActor.run(body: { state.repeatMode != .off }) {
                await setRepeatMode(.off)
            }
            if await MainActor.run(body: { state.isShuffled }) {
                await toggleShuffle()
            }
        }
        await MainActor.run { state.isAutoExtendEnabled = enabled }
        UserDefaults.standard.set(enabled, forKey: Self.autoExtendUserDefaultsKey)
        if enabled {
            await evaluateAutoExtend()
        } else {
            autoExtendFetchTask?.cancel()
            autoExtendFetchTask = nil
            await truncateExtensions()
        }
        Logger.player.info("Auto-extend \(enabled ? "enabled" : "disabled", privacy: .public)")
    }

    // MARK: - Auto-extend

    private func evaluateAutoExtend() async {
        let expectedQueueGeneration = queueGeneration
        let (isEnabled, repeatMode, currentRadio, remaining, queueIds, seedTrackId) = await MainActor.run {
            let remaining = state.queue.count - state.currentIndex - 1
            return (state.isAutoExtendEnabled, state.repeatMode, state.currentRadio, remaining, Set(state.queue.map(\.id)), state.currentTrack?.id)
        }
        guard expectedQueueGeneration == queueGeneration else { return }
        guard isEnabled else { return }
        guard repeatMode == .off else { return }
        guard currentRadio == nil else { return }
        guard autoExtendFetchTask == nil else { return }
        guard remaining <= 15 else { return }

        Logger.player.info("Auto-extend triggered: \(remaining) tracks remaining, fetching 50 seeded on '\(seedTrackId ?? "none", privacy: .public)'")

        autoExtendFetchGeneration &+= 1
        let fetchGeneration = autoExtendFetchGeneration
        autoExtendFetchTask = Task { [weak self] in
            await self?.performAutoExtendFetch(
                seedTrackId: seedTrackId,
                excludedIds: queueIds,
                queueGeneration: expectedQueueGeneration,
                fetchGeneration: fetchGeneration
            )
        }
    }

    private func performAutoExtendFetch(
        seedTrackId: String?,
        excludedIds: Set<String>,
        queueGeneration: UInt64,
        fetchGeneration: UInt64
    ) async {
        defer { clearAutoExtendFetchTask(fetchGeneration: fetchGeneration) }

        do {
            try Task.checkCancellation()
            let tracks = try await libraryService.endlessExtension(
                seedTrackId: seedTrackId,
                targetSize: 50,
                excludedIds: excludedIds
            )
            try Task.checkCancellation()
            guard !tracks.isEmpty else {
                Logger.player.debug("Auto-extend fetch returned empty — library exhausted or offline without downloads")
                return
            }
            guard await isAutoExtendContextValid(queueGeneration: queueGeneration) else {
                Logger.player.debug("Discarded stale auto-extend result")
                return
            }
            try Task.checkCancellation()
            let appendedCount = await commitAutoExtendedTracks(
                tracks,
                queueGeneration: queueGeneration
            )
            guard appendedCount > 0 else {
                Logger.player.debug("Discarded stale or duplicate auto-extend tracks")
                return
            }
            Logger.player.info("Auto-extend appended \(appendedCount) tracks to queue")
        } catch is CancellationError {
            Logger.player.debug("Auto-extend fetch cancelled")
        } catch {
            Logger.player.debug("Auto-extend fetch failed: \(error, privacy: .public)")
        }
    }

    private func clearAutoExtendFetchTask(fetchGeneration: UInt64) {
        guard fetchGeneration == autoExtendFetchGeneration else { return }
        autoExtendFetchTask = nil
    }

    private func isAutoExtendContextValid(queueGeneration: UInt64) async -> Bool {
        guard queueGeneration == self.queueGeneration else { return false }
        return await MainActor.run {
            state.queueGeneration == queueGeneration
                && state.isAutoExtendEnabled
                && state.repeatMode == .off
                && !state.isLiveStream
        }
    }

    private func commitAutoExtendedTracks(
        _ tracks: [DisplayableSong],
        queueGeneration: UInt64
    ) async -> Int {
        guard !tracks.isEmpty, queueGeneration == self.queueGeneration else { return 0 }
        let appendedCount = await MainActor.run {
            guard state.queueGeneration == queueGeneration,
                  state.isAutoExtendEnabled,
                  state.repeatMode == .off,
                  !state.isLiveStream
            else { return 0 }

            let existingIDs = Set(state.queue.map(\.id))
            let freshTracks = tracks.filter { !existingIDs.contains($0.id) }
            guard !freshTracks.isEmpty else { return 0 }
            if state.originalQueueEndIndex == nil {
                state.originalQueueEndIndex = state.queue.count
            }
            state.queue.append(contentsOf: freshTracks)
            return freshTracks.count
        }
        guard queueGeneration == self.queueGeneration, appendedCount > 0 else { return 0 }
        await saveSession()
        return appendedCount
    }

    /// New queue count after dropping the auto-extended tail, or `nil` when there is nothing to drop.
    ///
    /// Turning endless play off means "stop growing my queue", and the tracks it already grew are just
    /// as unwanted as the ones it would have added next — so they go too. The one thing never removed is
    /// the track currently playing: yanking it out mid-listen would stop the music on a toggle that says
    /// nothing about stopping. So inside the original zone the whole tail goes; inside the extended zone
    /// the current track survives as the new last entry and playback ends naturally after it.
    nonisolated static func truncationTarget(boundary: Int?, currentIndex: Int, queueCount: Int) -> Int? {
        guard let boundary, boundary < queueCount else { return nil }
        let target = currentIndex < boundary ? boundary : currentIndex + 1
        return target < queueCount ? target : nil
    }

    /// Drops the tracks auto-extend appended, keeping whatever is playing right now.
    private func truncateExtensions() async {
        let (boundary, currentIndex, queueCount) = await MainActor.run {
            (state.originalQueueEndIndex, state.currentIndex, state.queue.count)
        }
        guard let target = Self.truncationTarget(boundary: boundary, currentIndex: currentIndex, queueCount: queueCount) else {
            // Still clear the boundary: with endless play off it no longer marks anything, and leaving it
            // set would make a later re-enable anchor onto a stale index.
            await MainActor.run { state.originalQueueEndIndex = nil }
            return
        }
        await MainActor.run {
            state.queue = Array(state.queue[0..<target])
            state.originalQueueEndIndex = nil
        }
        Logger.player.info("Auto-extend tail truncated to \(target) of \(queueCount) (currentIndex=\(currentIndex), boundary=\(boundary ?? -1))")
    }

    // MARK: - Pause / Resume

    func pause() async {
        queueBuildGeneration &+= 1
        transportIntentGeneration &+= 1
        let transportGeneration = transportIntentGeneration
        cancelNetworkRecoveryProbe()
        cancelNetworkRecoveryValidation()
        pendingSystemResume = nil
        isRestoringSession = false
        Logger.player.info("[AUDIO-INTENT] pause origin=user-or-remote")

        await waitForTransitionCommit()
        guard transportGeneration == transportIntentGeneration, !Task.isCancelled else { return }
        beginTransitionCommit()
        defer { endTransitionCommit() }

        playbackProgressTracker.breakContinuity()
        engine.pause()
        // Flip the UI state BEFORE deactivating the audio session — setActive(false) routinely takes
        // hundreds of ms and used to hold the play/pause icon hostage behind it.
        await MainActor.run { state.playbackState = .paused }
        guard transportGeneration == transportIntentGeneration, !Task.isCancelled else { return }
        sessionActivationRetryTask?.cancel()
        sessionActivationRetryTask = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        stopProgressTimer()
        stopPositionSaveTimer()
        await pushPositionSnapshot(rate: 0.0)
        guard transportGeneration == transportIntentGeneration, !Task.isCancelled else { return }
        await saveSession()
    }

    func resume() async {
        queueBuildGeneration &+= 1
        transportIntentGeneration &+= 1
        let transportGeneration = transportIntentGeneration
        cancelNetworkRecoveryProbe()
        cancelNetworkRecoveryValidation()
        pendingSystemResume = nil
        Logger.player.info("[AUDIO-INTENT] play origin=user-or-system")
        // An explicit Play is a fresh user intent and must remain able to recover even when the
        // previous path already exhausted its automatic retry budget.
        networkRecoveryAttemptBudget.reset()
        isRestoringSession = false

        // Resuming after the queue ended restarts at track 0. A normal mid-track pause keeps the
        // current source. The planner owns that distinction so every resume entry point shares it.
        let wasStoppedAtEndOfQueue = stoppedAtEndOfQueue
        let transition = await queueTransitionSnapshot()
        guard transportGeneration == transportIntentGeneration, !Task.isCancelled else { return }
        let resumePlan = PlaybackTransitionPlanner.plan(
            for: .resumeRequested(stoppedAtEndOfQueue: wasStoppedAtEndOfQueue),
            snapshot: transition.planner
        )
        if wasStoppedAtEndOfQueue {
            stoppedAtEndOfQueue = false
        }
        if resumePlan == .restartQueue {
            try? await executeTransitionPlan(resumePlan, queue: transition.queue)
            return
        }

        // Cold restore, runtime error and network handover all need a new AVPlayerItem. `isReady`
        // only means `currentItem == nil`; a wedged item remains non-nil, so the track-specific
        // network marker must participate in this decision too.
        let coldStartSource: MediaSource?
        let coldStartTrackID: String?
        let coldStartDuration: TimeInterval?
        let coldStartPosition: TimeInterval?
        let resumeSnapshot = await MainActor.run {
            (
                trackID: state.currentTrack?.id,
                playbackState: state.playbackState,
                duration: state.duration,
                position: state.position
            )
        }
        guard transportGeneration == transportIntentGeneration, !Task.isCancelled else { return }
        let stateRequiresFreshItem: Bool
        if case .error = resumeSnapshot.playbackState {
            stateRequiresFreshItem = true
        } else {
            stateRequiresFreshItem = false
        }
        let pathRequiresFreshItem = resumeSnapshot.trackID == networkReloadRequiredTrackID
        let shouldStartFresh = engine.isReady || stateRequiresFreshItem || pathRequiresFreshItem

        if shouldStartFresh, let source = currentSource {
            coldStartSource = await refreshedColdStartSource() ?? source
            guard transportGeneration == transportIntentGeneration, !Task.isCancelled else { return }
            coldStartTrackID = resumeSnapshot.trackID ?? "restored"
            coldStartDuration = resumeSnapshot.duration
            coldStartPosition = resumeSnapshot.position
        } else {
            coldStartSource = nil
            coldStartTrackID = nil
            coldStartDuration = nil
            coldStartPosition = nil
        }

        await waitForTransitionCommit()
        guard transportGeneration == transportIntentGeneration, !Task.isCancelled else { return }
        beginTransitionCommit()
        defer { endTransitionCommit() }

        // User explicitly pressed play — cancel any pending restore auto-pause and lift eof guard.
        restorePauseTask?.cancel()
        restorePauseTask = nil
        if isMutedForRestore {
            engine.volume = restoredVolume
            isMutedForRestore = false
        }
        await MainActor.run { state.playbackState = .playing }
        guard transportGeneration == transportIntentGeneration, !Task.isCancelled else { return }
        configureAudioSessionIfNeeded()
        playbackProgressTracker.resume(at: engine.progress)

        if let freshSource = coldStartSource,
           let trackID = coldStartTrackID,
           let restoredDuration = coldStartDuration,
           let restartPosition = coldStartPosition {
            if let info = pendingRestoreInfo, info.pause {
                pendingRestoreInfo = (seekTime: info.seekTime, pause: false)
            } else if pendingRestoreInfo == nil {
                pendingRestoreInfo = (seekTime: restartPosition, pause: false)
            }
            if let info = pendingRestoreInfo, info.seekTime > 1 {
                engine.volume = 0
                isMutedForRestore = true
            }
            currentSource = freshSource
            engine.cancelPreload()
            let playbackToken = engine.play(
                trackID: trackID,
                url: freshSource.url,
                headers: freshSource.customHeaders
            )
            registerActiveEnginePlayback(
                playbackToken,
                playbackGeneration: playbackGeneration,
                transportIntentGeneration: transportGeneration
            )
            if networkReloadRequiredTrackID == trackID {
                networkRecoveryValidationToken = playbackToken
            }
            engine.setTrackDuration(restoredDuration)
        } else {
            if let activeEnginePlayback {
                self.activeEnginePlayback = ActiveEnginePlayback(
                    token: activeEnginePlayback.token,
                    playbackGeneration: playbackGeneration,
                    transportIntentGeneration: transportGeneration
                )
            }
            engine.resume()
        }
        await pushPositionSnapshot(rate: 1.0)
        guard transportGeneration == transportIntentGeneration, !Task.isCancelled else { return }
        startProgressTimer()
        startPositionSaveTimer()
    }

    /// Fresh download > cache > stream resolution for the cold-start resume path.
    /// Returns nil (caller keeps the stored source) when the track or server is
    /// unknown or resolution fails — local copies resolve without any network.
    private func refreshedColdStartSource() async -> MediaSource? {
        guard let track = await MainActor.run(body: { state.currentTrack }),
              let serverId = await MainActor.run(body: { serverService.state.activeServer?.id }) else { return nil }
        do {
            return try await mediaResolver.resolve(songId: track.id, serverId: serverId)
        } catch {
            Logger.player.warning("[RESTORE] cold-start re-resolve failed — keeping stored source: \(error, privacy: .public)")
            return nil
        }
    }

    func togglePlayPause() async {
        let isPlaying = await MainActor.run { state.playbackState == .playing }
        if isPlaying { await pause() } else { await resume() }
    }

    // MARK: - Stop

    func stop() async {
        queueBuildGeneration &+= 1
        playbackGeneration &+= 1
        transportIntentGeneration &+= 1
        let generation = playbackGeneration
        let transportGeneration = transportIntentGeneration
        cancelNetworkRecoveryProbe()
        cancelNetworkRecoveryValidation()
        pendingSystemResume = nil
        networkReloadRequiredTrackID = nil
        networkRecoveryAttemptBudget.reset()
        await waitForTransitionCommit()
        guard isCurrentPlaybackIntent(
            playbackGeneration: generation,
            transportIntentGeneration: transportGeneration
        ) else { return }
        beginTransitionCommit()
        defer { endTransitionCommit() }

        await recordCurrentTrackPlayback(trigger: "stopped")
        guard isCurrentPlaybackIntent(
            playbackGeneration: generation,
            transportIntentGeneration: transportGeneration
        ) else { return }
        cancelPendingScrobble()
        cancelPendingCacheDownload()
        cancelPendingPrefetch()
        cancelPendingInstantMix()
        stopProgressTimer()
        stopPositionSaveTimer()
        restorePauseTask?.cancel()
        restorePauseTask = nil
        if isMutedForRestore {
            engine.volume = restoredVolume
            isMutedForRestore = false
        }
        liveStreamStallTask?.cancel()
        liveStreamStallTask = nil
        autoExtendFetchTask?.cancel()
        autoExtendFetchTask = nil
        engine.stop()
        activeEnginePlayback = nil
        sessionActivationRetryTask?.cancel()
        sessionActivationRetryTask = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        playbackProgressTracker.reset()
        engine.applyReplayGain(dB: 0)
        currentSource = nil
        pendingRestoreInfo = nil
        isRestoringSession = false
        await nowPlayingService?.stop()
        await sessionService.clear()
        queueGeneration &+= 1
        let stoppedQueueGeneration = queueGeneration
        await MainActor.run {
            state.queueGeneration = stoppedQueueGeneration
            state.playbackState = .idle
            state.currentTrack = nil
            state.currentRadio = nil
            state.isSmartShuffleActive = false
            state.originalQueueEndIndex = nil
            state.queue = []
            state.position = 0
            state.duration = 0
        }
    }

    // MARK: - Seek

    nonisolated static func clampedSeekTarget(
        requested: TimeInterval,
        stateDuration: TimeInterval,
        engineDuration: TimeInterval
    ) -> TimeInterval? {
        guard requested.isFinite else { return nil }
        let knownDuration = max(
            stateDuration.isFinite ? stateDuration : 0,
            engineDuration.isFinite ? engineDuration : 0
        )
        let nonnegative = max(requested, 0)
        return knownDuration > 0 ? min(nonnegative, knownDuration) : nonnegative
    }

    func seek(to position: TimeInterval) async {
        // Reject malformed targets (NaN/inf). A scrubber drag against a zero-width track produces NaN, which
        // would corrupt the engine's seek math. The single chokepoint for every
        // seek caller (UI, lyrics, lock screen). A malformed seek is a silent no-op — NOT a jump to zero.
        let stateDuration = await MainActor.run { state.duration }
        let engineDuration = engine.duration
        guard let target = Self.clampedSeekTarget(
            requested: position,
            stateDuration: stateDuration,
            engineDuration: engineDuration
        ) else {
            Logger.player.warning("seek ignored — non-finite target")
            return
        }
        guard await MainActor.run(body: { !state.isLiveStream }) else {
            Logger.player.debug("seek ignored — live stream mode")
            return
        }
        seekGeneration &+= 1
        let requestedSeekGeneration = seekGeneration
        let requestedPlaybackGeneration = playbackGeneration
        let before = engine.progress
        let wasSeekable = engine.isSeekable
        Logger.player.info(
            "[SEEK] request target=\(target, format: .fixed(precision: 3))s before=\(before, format: .fixed(precision: 3))s stateDuration=\(stateDuration, format: .fixed(precision: 3))s engineDuration=\(engineDuration, format: .fixed(precision: 3))s seekable=\(wasSeekable, privacy: .public)"
        )
        // Finalize the current segment and start a fresh one so that only
        // audio actually heard after the seek point is counted in played time.
        playbackProgressTracker.breakContinuity()
        let succeeded = await engine.seek(to: target)
        let landed = engine.progress
        guard requestedSeekGeneration == seekGeneration,
              requestedPlaybackGeneration == playbackGeneration else {
            Logger.player.debug("[SEEK] discarded stale completion for target=\(target, format: .fixed(precision: 3))s")
            return
        }
        guard succeeded else {
            Logger.player.warning(
                "[SEEK] failed target=\(target, format: .fixed(precision: 3))s landed=\(landed, format: .fixed(precision: 3))s"
            )
            await MainActor.run { state.position = landed.isFinite ? max(landed, 0) : before }
            await pushPositionSnapshot()
            return
        }
        let confirmedPosition = landed.isFinite ? max(landed, 0) : target
        playbackProgressTracker.setBaseline(confirmedPosition)
        await MainActor.run { state.position = confirmedPosition }
        Logger.player.info(
            "[SEEK] completed target=\(target, format: .fixed(precision: 3))s landed=\(confirmedPosition, format: .fixed(precision: 3))s"
        )
        await pushPositionSnapshot()
    }

    // MARK: - Skip

    func skipToNext() async throws {
        guard await MainActor.run(body: { !state.isLiveStream }) else {
            Logger.player.debug("skipToNext ignored — live stream mode")
            return
        }
        let transition = await queueTransitionSnapshot()
        let nextIndex = transition.planner.currentIndex + 1
        Logger.player.info("[TRANSITION] skipToNext: currentIndex=\(transition.planner.currentIndex) nextIndex=\(nextIndex) queueCount=\(transition.queue.count)")
        let plan = PlaybackTransitionPlanner.plan(
            for: .nextRequested,
            snapshot: transition.planner
        )
        try await executeTransitionPlan(plan, queue: transition.queue)
    }

    func skipToPrevious() async throws {
        guard await MainActor.run(body: { !state.isLiveStream }) else {
            Logger.player.debug("skipToPrevious ignored — live stream mode")
            return
        }
        let transition = await queueTransitionSnapshot()
        let plan = PlaybackTransitionPlanner.plan(
            for: .previousRequested(position: transition.position),
            snapshot: transition.planner
        )
        try await executeTransitionPlan(plan, queue: transition.queue)
    }

    private func queueTransitionSnapshot() async -> (
        queue: [DisplayableSong],
        planner: PlaybackTransitionPlanner.Snapshot,
        position: TimeInterval
    ) {
        await MainActor.run {
            (
                state.queue,
                .init(
                    queueCount: state.queue.count,
                    currentIndex: state.currentIndex,
                    repeatMode: state.repeatMode
                ),
                state.position
            )
        }
    }

    /// Executes a pure transition plan. All I/O and actor hops stay here; the planner contains only
    /// the queue policy and completion attribution.
    private func executeTransitionPlan(
        _ plan: PlaybackTransitionPlanner.Plan,
        queue: [DisplayableSong]
    ) async throws {
        switch plan {
        case .playQueueItem(let index, let currentTrackOutcome):
            guard queue.indices.contains(index) else { return }
            wasTrackCompletedNaturally = currentTrackOutcome == .completed
            let next = queue[index]
            Logger.player.info(
                "[TRANSITION] queue item \(index) → id=\(next.id, privacy: .public) title=\(next.title, privacy: .public) outcome=\(String(describing: currentTrackOutcome), privacy: .public)"
            )
            try await play(tracks: queue, startIndex: index)

        case .restartCurrent:
            await seek(to: 0)

        case .repeatCurrent:
            wasTrackCompletedNaturally = true
            await recordCurrentTrackPlayback(trigger: "repeat_one")
            wasTrackCompletedNaturally = false
            playbackProgressTracker.startTrack()
            if let source = currentSource {
                let trackID = await MainActor.run { state.currentTrack?.id ?? "repeat" }
                let playbackToken = engine.play(
                    trackID: trackID,
                    url: source.url,
                    headers: source.customHeaders
                )
                registerActiveEnginePlayback(
                    playbackToken,
                    playbackGeneration: playbackGeneration,
                    transportIntentGeneration: transportIntentGeneration
                )
            }

        case .stopAtEnd(let currentTrackOutcome):
            wasTrackCompletedNaturally = currentTrackOutcome == .completed
            await pauseAtEndOfQueue()

        case .restartQueue:
            guard !queue.isEmpty else { return }
            pendingRestoreInfo = nil
            try await play(tracks: queue, startIndex: 0)

        case .resumeCurrent:
            break
        }
    }

    // MARK: - Queue management

    func setRepeatMode(_ mode: RepeatMode) async {
        guard await MainActor.run(body: { !state.isLiveStream }) else {
            Logger.player.debug("setRepeatMode ignored — live stream mode")
            return
        }
        if mode != .off, await MainActor.run(body: { state.isAutoExtendEnabled }) {
            await setAutoExtendEnabled(false)
        }
        let previousMode = await MainActor.run { state.repeatMode }
        await MainActor.run { state.repeatMode = mode }
        // Activating any loop mode while in the original zone truncates the auto-extended tail.
        if previousMode == .off && mode != .off {
            await truncateExtensions()
        }
        // Deactivating loop may newly satisfy the auto-extend repeat guard — re-evaluate.
        if previousMode != .off && mode == .off {
            await evaluateAutoExtend()
        }
        await saveSession()
    }

    func toggleShuffle() async {
        guard await MainActor.run(body: { !state.isLiveStream }) else {
            Logger.player.debug("toggleShuffle ignored — live stream mode")
            return
        }
        let isCurrentlyShuffled = await MainActor.run { state.isShuffled }
        if isCurrentlyShuffled {
            await restoreOriginalQueueOrder()
            await MainActor.run { state.isShuffled = false }
        } else {
            if await MainActor.run(body: { state.isAutoExtendEnabled }) {
                await setAutoExtendEnabled(false)
            }
            await shuffleUpNext()
            await MainActor.run { state.isShuffled = true }
        }
        await saveSession()
    }

    private func shuffleUpNext() async {
        let (queue, currentIndex) = await MainActor.run { (state.queue, state.currentIndex) }
        originalQueueOrder = queue
        guard currentIndex + 1 < queue.count else { return }
        let head = Array(queue[...currentIndex])
        let shuffled = Array(queue[(currentIndex + 1)...]).shuffled()
        await MainActor.run { state.queue = head + shuffled }
    }

    private func restoreOriginalQueueOrder() async {
        guard let original = originalQueueOrder,
              let currentTrack = await MainActor.run(body: { state.currentTrack }),
              let restoredIndex = original.firstIndex(where: { $0.id == currentTrack.id })
        else { return }
        await MainActor.run {
            state.queue = original
            state.currentIndex = restoredIndex
        }
        originalQueueOrder = nil
    }

    func appendToQueue(_ tracks: [DisplayableSong]) async {
        guard await MainActor.run(body: { !state.isLiveStream }) else {
            Logger.player.debug("appendToQueue ignored — live stream mode")
            return
        }
        await MainActor.run {
            state.queue.append(contentsOf: tracks)
            // Once the user edits an already extended tail, a single integer can no longer distinguish
            // generated and intentional entries safely. Preserve everything rather than deleting user work.
            if state.originalQueueEndIndex != nil {
                state.originalQueueEndIndex = state.queue.count
            }
        }
        await saveSession()
    }

    func playNext(_ songs: [DisplayableSong]) async {
        guard await MainActor.run(body: { !state.isLiveStream }) else {
            Logger.player.debug("playNext ignored — live stream mode")
            return
        }
        let (queue, currentIndex) = await MainActor.run { (state.queue, state.currentIndex) }
        if queue.isEmpty {
            do {
                try await play(tracks: songs, startIndex: 0)
            } catch {
                Logger.player.error("[PLAYBACK] playNext: play() failed on empty queue: \(error, privacy: .public)")
            }
        } else {
            let insertAt = min(currentIndex + 1, queue.count)
            await MainActor.run {
                state.queue.insert(contentsOf: songs, at: insertAt)
                if let boundary = state.originalQueueEndIndex, insertAt <= boundary {
                    state.originalQueueEndIndex = boundary + songs.count
                }
            }
            Logger.player.info("Inserted \(songs.count) song(s) at queue position \(insertAt)")
            await saveSession()
            if !songs.isEmpty {
                await presentQueueConfirmation(
                    String(localized: "\(songs.count) songs playing next"),
                    coverArtId: songs.first?.coverArtId
                )
            }
        }
        // Empty-queue Play Next falls back to play() above and starts playback immediately,
        // which is its own visible feedback — no confirmation toast there, matching Play.
    }

    func playNext(_ song: DisplayableSong) async {
        await playNext([song])
    }

    func addToQueue(_ songs: [DisplayableSong]) async {
        await appendToQueue(songs)
        // appendToQueue is also the silent leaf for background auto-extend, so the confirmation
        // lives here on the user-facing path. Re-check live stream: appendToQueue no-ops on radio.
        guard !songs.isEmpty,
              await MainActor.run(body: { !state.isLiveStream }) else { return }
        await presentQueueConfirmation(
            String(localized: "\(songs.count) songs added to queue"),
            coverArtId: songs.first?.coverArtId
        )
    }

    func addToQueue(_ song: DisplayableSong) async {
        await addToQueue([song])
    }

    /// Presents an enqueue confirmation toast on the main actor. Callers guard against empty
    /// batches (failed lazy loads) and live-stream mode so those no-op paths stay silent.
    private func presentQueueConfirmation(_ message: String, coverArtId: String? = nil) async {
        await MainActor.run { toastService.showConfirmation(message, coverArtId: coverArtId) }
    }

    func removeFromQueue(at index: Int) async {
        guard await MainActor.run(body: { !state.isLiveStream }) else {
            Logger.player.debug("removeFromQueue ignored — live stream mode")
            return
        }
        let (queueCount, currentIndex, isShuffled) = await MainActor.run {
            (state.queue.count, state.currentIndex, state.isShuffled)
        }
        guard index >= 0, index < queueCount else { return }
        guard index != currentIndex else {
            Logger.player.warning("removeFromQueue: index \(index) is current track — ignored")
            return
        }
        await MainActor.run {
            state.queue.remove(at: index)
            if index < state.currentIndex { state.currentIndex -= 1 }
            if let boundary = state.originalQueueEndIndex, index < boundary {
                state.originalQueueEndIndex = max(0, boundary - 1)
            }
        }
        if isShuffled { originalQueueOrder = nil }
        let newIdx = await MainActor.run { state.currentIndex }
        Logger.player.info("Removed track at \(index), currentIndex now \(newIdx)")
        await saveSession()
    }

    func moveInQueue(fromIndex: Int, toIndex: Int) async {
        guard await MainActor.run(body: { !state.isLiveStream }) else {
            Logger.player.debug("moveInQueue ignored — live stream mode")
            return
        }
        let (queueCount, currentIndex, isShuffled) = await MainActor.run {
            (state.queue.count, state.currentIndex, state.isShuffled)
        }
        guard fromIndex >= 0, fromIndex < queueCount else { return }
        guard toIndex >= 0, toIndex <= queueCount else { return }
        guard fromIndex != toIndex else { return }
        await MainActor.run {
            // Replicates Array.move(fromOffsets:toOffset:) semantics without SwiftUI:
            // element ends up at toIndex-1 when fromIndex < toIndex, or toIndex otherwise.
            let song = state.queue.remove(at: fromIndex)
            let dest = fromIndex < toIndex ? toIndex - 1 : toIndex
            state.queue.insert(song, at: dest)
            if fromIndex == currentIndex {
                state.currentIndex = fromIndex < toIndex ? toIndex - 1 : toIndex
            } else if fromIndex < currentIndex && toIndex > currentIndex {
                state.currentIndex -= 1
            } else if fromIndex > currentIndex && toIndex <= currentIndex {
                state.currentIndex += 1
            }
            // Moving across the boundary destroys the contiguous-tail invariant. Keeping the queue is
            // safer than allowing a later toggle to truncate an intentional track.
            state.originalQueueEndIndex = nil
        }
        if isShuffled { originalQueueOrder = nil }
        let newIdx = await MainActor.run { state.currentIndex }
        Logger.player.info("Moved track \(fromIndex)→\(toIndex), currentIndex now \(newIdx)")
        await saveSession()
    }

    // MARK: - Session persistence

    /// Lightweight position-only flush — called from scenePhase .inactive on iOS
    /// to protect the current position against a fast process kill.
    func saveCurrentPosition() async {
        guard await MainActor.run(body: { !state.isLiveStream && state.currentTrack != nil }) else { return }
        let pos = engine.progress
        guard pos > 0 else { return }
        await sessionService.savePosition(pos)
    }

    private func saveSession() async {
        let snapshot = await MainActor.run {
            SessionPayload(
                currentIndex: state.currentIndex,
                currentPosition: state.position,
                queue: state.queue,
                currentTrack: state.currentTrack,
                repeatMode: state.repeatMode
            )
        }
        await sessionService.save(playerState: snapshot)
    }

    func restoreSession() async {
        queueBuildGeneration &+= 1
        playbackGeneration &+= 1
        transportIntentGeneration &+= 1
        let generation = playbackGeneration
        let transportGeneration = transportIntentGeneration

        guard let data = await sessionService.loadRestoredSession() else { return }
        guard isCurrentPlaybackIntent(
            playbackGeneration: generation,
            transportIntentGeneration: transportGeneration
        ), data.queue.indices.contains(data.currentIndex) else { return }

        let track = data.queue[data.currentIndex]
        let restoredDuration = max(data.currentTrackDuration, track.duration)
        let nonnegativePosition = max(data.currentPosition, 0)
        let restoredPosition = restoredDuration > 0
            ? min(nonnegativePosition, restoredDuration)
            : nonnegativePosition
        queueGeneration &+= 1
        let restoredQueueGeneration = queueGeneration
        await MainActor.run {
            state.queueGeneration = restoredQueueGeneration
            state.queue = data.queue
            state.currentIndex = data.currentIndex
            state.currentTrack = track
            state.currentRadio = nil
            state.position = restoredPosition
            state.duration = restoredDuration
            state.repeatMode = data.repeatMode
            state.playbackState = .paused
        }
        guard isCurrentPlaybackIntent(
            playbackGeneration: generation,
            transportIntentGeneration: transportGeneration
        ) else { return }

        // If the saved session was parked at the END of the last track (the queue had finished, repeat off),
        // mark it so resume() restarts from track 0 instead of replaying the last track's tail and immediately
        // hitting EOF — a phantom transition at cold start. pauseAtEndOfQueue parks position exactly at duration,
        // and a mid-track pause leaves position < duration, so the tight epsilon distinguishes the two.
        if data.repeatMode == .off,
           data.currentIndex == data.queue.count - 1,
           data.currentTrackDuration > 0,
           data.currentPosition >= data.currentTrackDuration - 0.1 {
            stoppedAtEndOfQueue = true
            Logger.player.info("[RESTORE] session was parked at end of queue — resume will restart from track 0")
        }

        await prepareCurrentTrackForRestoration(
            track: track,
            position: restoredPosition,
            generation: generation,
            transportGeneration: transportGeneration
        )
        guard isCurrentPlaybackIntent(
            playbackGeneration: generation,
            transportIntentGeneration: transportGeneration
        ) else { return }
        Logger.player.info("Session restored: \(data.queue.count) tracks, index \(data.currentIndex), pos=\(restoredPosition, format: .fixed(precision: 1))s")
    }

    private func prepareCurrentTrackForRestoration(
        track: DisplayableSong,
        position: TimeInterval,
        generation: UInt64,
        transportGeneration: UInt64
    ) async {
        guard isCurrentPlaybackIntent(
            playbackGeneration: generation,
            transportIntentGeneration: transportGeneration
        ) else { return }
        // Set the guard immediately — before any await — so a network-path event cannot
        // race in during mediaResolver.resolve() and trigger a second play() call that would
        // consume pendingRestoreInfo before the deferred seek is applied.
        isRestoringSession = true
        defer {
            if generation == playbackGeneration,
               transportGeneration == transportIntentGeneration {
                isRestoringSession = false
            }
        }

        let activeServerID = await MainActor.run { serverService.state.activeServer?.id }
        guard isCurrentPlaybackIntent(
            playbackGeneration: generation,
            transportIntentGeneration: transportGeneration
        ) else { return }
        guard let serverId = activeServerID else {
            Logger.player.warning("Session restore: no active server, skipping player prep")
            return
        }

        let source: MediaSource
        do {
            source = try await mediaResolver.resolve(songId: track.id, serverId: serverId)
        } catch {
            guard isCurrentPlaybackIntent(
                playbackGeneration: generation,
                transportIntentGeneration: transportGeneration
            ) else { return }
            Logger.player.error("Session restore: failed to resolve media — \(error)")
            await MainActor.run { state.isPlaybackAvailable = false }
            return
        }
        guard isCurrentPlaybackIntent(
            playbackGeneration: generation,
            transportIntentGeneration: transportGeneration
        ) else { return }

        stopProgressTimer()
        currentSource = source
        networkReloadRequiredTrackID = nil
        cancelNetworkRecoveryValidation()
        networkRecoveryAttemptBudget.reset()
        // Seek to saved position on first play; pause flag cleared in resume() when user
        // explicitly starts playback, or kept if user hasn't tapped play yet.
        pendingRestoreInfo = (seekTime: position, pause: true)

        // Apply ReplayGain after restore state is fully committed (no suspension between
        // currentSource and pendingRestoreInfo above). globalGain is set on the EQ node
        // and takes effect when audio flows, so applying while paused is correct.
        let config = await MainActor.run { replayGainSettings.config }
        guard isCurrentPlaybackIntent(
            playbackGeneration: generation,
            transportIntentGeneration: transportGeneration
        ) else { return }
        engine.applyReplayGain(dB: ReplayGainService.gainDB(track: track, config: config))
        Logger.player.debug("[RESTORE] ReplayGain applied for '\(track.title, privacy: .public)'")

        // Session activation is intentionally deferred to the first user-triggered play.
        // Activating here would grab the audio route from other devices (e.g. Mac+AirPods)
        // before the user has indicated intent to listen.

        await MainActor.run { state.isPlaybackAvailable = true }
        guard isCurrentPlaybackIntent(
            playbackGeneration: generation,
            transportIntentGeneration: transportGeneration
        ) else { return }
        Logger.player.info("Session restore: '\(track.title)' queued at \(position, format: .fixed(precision: 1))s (playback deferred)")

        // Populate MPNowPlayingInfoCenter in paused state so lock screen controls appear
        // immediately when the user resumes — resume() only sends a position-only update
        // which would start from an empty dict otherwise.
        let duration = await MainActor.run { state.duration }
        guard isCurrentPlaybackIntent(
            playbackGeneration: generation,
            transportIntentGeneration: transportGeneration
        ) else { return }
        let artworkURL = await resolveArtworkURL(for: track)
        guard isCurrentPlaybackIntent(
            playbackGeneration: generation,
            transportIntentGeneration: transportGeneration
        ) else { return }
        let artworkHeaders: [String: String]
        do {
            artworkHeaders = try await serverService.activeCredentials().customHeaders
        } catch {
            Logger.player.warning("[CREDENTIALS] activeCredentials failed, using empty headers: \(error, privacy: .public)")
            artworkHeaders = [:]
        }
        guard isCurrentPlaybackIntent(
            playbackGeneration: generation,
            transportIntentGeneration: transportGeneration
        ) else { return }
        await nowPlayingService?.update(with: NowPlayingSnapshot(
            title: track.title,
            artist: track.artist,
            album: track.albumName,
            duration: duration,
            position: position,
            playbackRate: 0.0,
            artworkURL: artworkURL,
            artworkHeaders: artworkHeaders,
            coverArtId: track.coverArtId,
            isLiveStream: false,
            radioStationName: nil,
            songId: track.id
        ))
    }

    // MARK: - Network-path recovery

    func handleNetworkPathChanged(_ event: NetworkPathEvent) async {
        // Generation zero is the launch baseline. Reject duplicate or out-of-order events too: the
        // AsyncStream is newest-only and a cancelled SwiftUI task can finish after its replacement.
        guard event.generation > 0,
              event.generation > latestNetworkPathEvent.generation else { return }

        latestNetworkPathEvent = event
        cancelNetworkRecoveryProbe()
        cancelNetworkRecoveryValidation()
        cancelPendingPrefetch()
        cancelPendingCacheDownload()
        // Drop the standby item immediately. It may be `.readyToPlay` while its HTTP connection is
        // still tied to the previous interface, and manual Next would otherwise promote it.
        engine.cancelPreload()

        let generation = playbackGeneration
        let transportGeneration = transportIntentGeneration
        let snapshot = await MainActor.run {
            (
                track: state.currentTrack,
                playbackState: state.playbackState,
                position: state.position,
                duration: state.duration,
                isAvailable: state.isPlaybackAvailable
            )
        }
        guard generation == playbackGeneration,
              transportGeneration == transportIntentGeneration else { return }

        // Preserve cold-session restoration: unlike an active stream failure, this path has no
        // AVPlayerItem yet and `isPlaybackAvailable` explicitly records that resolution failed.
        if event.isOnline,
           !snapshot.isAvailable,
           let track = snapshot.track,
           !isRestoringSession {
            Logger.player.info("Network path restored — re-preparing '\(track.title, privacy: .public)'")
            await prepareCurrentTrackForRestoration(
                track: track,
                position: snapshot.position,
                generation: generation,
                transportGeneration: transportGeneration
            )
            return
        }

        guard let track = snapshot.track else {
            networkReloadRequiredTrackID = nil
            return
        }
        let sourceIsRemote = currentSourceIsRemoteStream
        let action = Self.networkRecoveryAction(
            sourceIsRemoteStream: sourceIsRemote,
            isOnline: event.isOnline,
            playbackState: snapshot.playbackState
        )
        guard action != .none else {
            networkReloadRequiredTrackID = nil
            return
        }

        // Keep consuming any already-buffered audio while offline. The marker forces a fresh item
        // on explicit Resume, or arms recovery when AVPlayer later reports a real stall.
        networkReloadRequiredTrackID = track.id
        Logger.player.info(
            "[NETWORK-RECOVERY] path generation=\(event.generation, privacy: .public) online=\(event.isOnline, privacy: .public) marked track='\(track.id, privacy: .public)'"
        )

        guard action == .armAutomaticRecovery else { return }
        switch snapshot.playbackState {
        case .error:
            armNetworkRecoveryProbe(trackID: track.id, delay: .seconds(1), requireStall: false)
        case .playing:
            // The engine may have emitted `.paused` while the path was offline. NWPath returning
            // online does not guarantee another KVO callback, so explicitly reassert the still-live
            // user intent now. `play()` is idempotent if buffered audio never stopped.
            if Self.shouldReassertPlaybackOnOnlinePath(
                sourceIsRemoteStream: sourceIsRemote,
                isOnline: event.isOnline,
                playbackState: snapshot.playbackState,
                position: snapshot.position,
                duration: snapshot.duration
            ) {
                configureAudioSessionIfNeeded()
                engine.resume()
                Logger.player.info(
                    "[NETWORK-RECOVERY] reasserted playback on online path track='\(track.id, privacy: .public)'"
                )
            }
            // A satisfied Wi-Fi path can be published before DNS, the proxy, or the media server is
            // usable. Keep the audible item and rebuild only if its playhead actually stops moving.
            armNetworkRecoveryProbe(trackID: track.id, delay: .seconds(2), requireStall: true)
        case .idle, .loading, .paused:
            // A seamless handover stays audible. Do not manufacture a gap; explicit Play rebuilds.
            break
        }
    }

    private func cancelNetworkRecoveryProbe() {
        networkRecoveryTask?.cancel()
        networkRecoveryTask = nil
        networkRecoveryTaskGeneration &+= 1
    }

    private func cancelNetworkRecoveryValidation() {
        networkRecoveryValidationTask?.cancel()
        networkRecoveryValidationTask = nil
        networkRecoveryValidationGeneration &+= 1
        networkRecoveryValidationToken = nil
    }

    /// A transient `.playing` is not enough to prove that a rebuilt HTTP item survived the new
    /// interface. Validate actual playhead movement after the restore seek before clearing the marker.
    private func armNetworkRecoveryValidation(
        playbackToken: AudioEnginePlaybackToken,
        trackID: String
    ) {
        guard networkRecoveryValidationTask == nil,
              networkRecoveryValidationToken == playbackToken,
              networkReloadRequiredTrackID == trackID else { return }

        let validationGeneration = networkRecoveryValidationGeneration
        let pathGeneration = latestNetworkPathEvent.generation
        let expectedPlaybackGeneration = playbackGeneration
        let expectedTransportGeneration = transportIntentGeneration
        let baselineProgress = engine.progress

        networkRecoveryValidationTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            await self.performNetworkRecoveryValidation(
                playbackToken: playbackToken,
                trackID: trackID,
                pathGeneration: pathGeneration,
                expectedPlaybackGeneration: expectedPlaybackGeneration,
                expectedTransportGeneration: expectedTransportGeneration,
                validationGeneration: validationGeneration,
                baselineProgress: baselineProgress
            )
        }
    }

    private func performNetworkRecoveryValidation(
        playbackToken: AudioEnginePlaybackToken,
        trackID: String,
        pathGeneration: UInt64,
        expectedPlaybackGeneration: UInt64,
        expectedTransportGeneration: UInt64,
        validationGeneration: UInt64,
        baselineProgress: TimeInterval
    ) async {
        defer {
            if validationGeneration == networkRecoveryValidationGeneration {
                networkRecoveryValidationTask = nil
            }
        }
        guard !Task.isCancelled,
              validationGeneration == networkRecoveryValidationGeneration,
              pathGeneration == latestNetworkPathEvent.generation,
              latestNetworkPathEvent.isOnline,
              expectedPlaybackGeneration == playbackGeneration,
              expectedTransportGeneration == transportIntentGeneration,
              networkRecoveryValidationToken == playbackToken,
              networkReloadRequiredTrackID == trackID,
              isCurrentEngineEvent(playbackToken) else { return }

        let snapshot = await MainActor.run {
            (trackID: state.currentTrack?.id, playbackState: state.playbackState, duration: state.duration)
        }
        guard !Task.isCancelled,
              validationGeneration == networkRecoveryValidationGeneration,
              isCurrentEngineEvent(playbackToken),
              snapshot.trackID == trackID else { return }

        guard snapshot.playbackState == .playing else {
            // User/system pause wins. Keep the track marker so a later explicit Play opens a fresh item.
            networkRecoveryValidationToken = nil
            return
        }

        let progress = engine.progress
        switch Self.networkProgressValidationOutcome(
            baseline: baselineProgress,
            current: progress,
            duration: snapshot.duration
        ) {
        case .validated:
            networkRecoveryValidationToken = nil
            networkReloadRequiredTrackID = nil
            networkRecoveryAttemptBudget.reset()
            cancelNetworkRecoveryProbe()
            Logger.player.info(
                "[NETWORK-RECOVERY] rebuilt item validated by progress track='\(trackID, privacy: .public)'"
            )
            return
        case .deferToEndOfTrack:
            // Let the normal EOF transition own a clock parked at the end.
            networkRecoveryValidationToken = nil
            return
        case .retry:
            break
        }

        networkRecoveryValidationToken = nil
        Logger.player.warning(
            "[NETWORK-RECOVERY] rebuilt item did not advance track='\(trackID, privacy: .public)' — retrying"
        )
        armNetworkRecoveryProbe(trackID: trackID, delay: .milliseconds(250), requireStall: false)
    }

    private func armNetworkRecoveryProbe(
        trackID: String,
        delay: Duration,
        requireStall: Bool
    ) {
        let pathGeneration = latestNetworkPathEvent.generation
        guard networkRecoveryAttemptBudget.canAttempt(
            trackID: trackID,
            pathGeneration: pathGeneration
        ) else {
            Logger.player.warning(
                "[NETWORK-RECOVERY] retry budget exhausted track='\(trackID, privacy: .public)' path=\(pathGeneration, privacy: .public)"
            )
            return
        }

        cancelNetworkRecoveryProbe()
        let requestGeneration = networkRecoveryTaskGeneration
        let expectedPlaybackGeneration = playbackGeneration
        let expectedTransportGeneration = transportIntentGeneration
        let baselineProgress = engine.progress

        networkRecoveryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            await self.performNetworkRecoveryProbe(
                trackID: trackID,
                pathGeneration: pathGeneration,
                expectedPlaybackGeneration: expectedPlaybackGeneration,
                expectedTransportGeneration: expectedTransportGeneration,
                requestGeneration: requestGeneration,
                baselineProgress: baselineProgress,
                requireStall: requireStall
            )
        }
    }

    private func performNetworkRecoveryProbe(
        trackID: String,
        pathGeneration: UInt64,
        expectedPlaybackGeneration: UInt64,
        expectedTransportGeneration: UInt64,
        requestGeneration: UInt64,
        baselineProgress: TimeInterval,
        requireStall: Bool
    ) async {
        defer {
            if requestGeneration == networkRecoveryTaskGeneration {
                networkRecoveryTask = nil
            }
        }
        guard !Task.isCancelled,
              requestGeneration == networkRecoveryTaskGeneration,
              pathGeneration == latestNetworkPathEvent.generation,
              latestNetworkPathEvent.isOnline,
              expectedPlaybackGeneration == playbackGeneration,
              expectedTransportGeneration == transportIntentGeneration,
              networkReloadRequiredTrackID == trackID else { return }

        let snapshot = await MainActor.run {
            (
                track: state.currentTrack,
                playbackState: state.playbackState,
                position: state.position,
                duration: state.duration,
                serverID: serverService.state.activeServer?.id,
                replayGainConfig: replayGainSettings.config
            )
        }
        guard !Task.isCancelled,
              requestGeneration == networkRecoveryTaskGeneration,
              pathGeneration == latestNetworkPathEvent.generation,
              expectedPlaybackGeneration == playbackGeneration,
              expectedTransportGeneration == transportIntentGeneration,
              snapshot.track?.id == trackID,
              let track = snapshot.track,
              let serverID = snapshot.serverID else { return }

        switch snapshot.playbackState {
        case .playing, .error:
            break
        case .idle, .loading, .paused:
            // A user pause/stop always wins. Keep the marker for the next explicit Resume.
            return
        }

        let currentProgress = engine.progress
        if requireStall, currentProgress > baselineProgress + 0.1 {
            cancelNetworkRecoveryValidation()
            networkReloadRequiredTrackID = nil
            networkRecoveryAttemptBudget.reset()
            Logger.player.debug(
                "[NETWORK-RECOVERY] existing item validated on new path track='\(trackID, privacy: .public)'"
            )
            return
        }

        guard let attempt = networkRecoveryAttemptBudget.beginAttempt(
            trackID: trackID,
            pathGeneration: pathGeneration
        ) else { return }

        let freshSource: MediaSource
        do {
            freshSource = try await mediaResolver.resolve(songId: trackID, serverId: serverID)
        } catch {
            Logger.player.warning(
                "[NETWORK-RECOVERY] source refresh attempt=\(attempt, privacy: .public) failed track='\(trackID, privacy: .public)': \(error, privacy: .public)"
            )
            armNetworkRecoveryProbe(trackID: trackID, delay: .seconds(2), requireStall: false)
            return
        }
        guard !Task.isCancelled,
              requestGeneration == networkRecoveryTaskGeneration,
              pathGeneration == latestNetworkPathEvent.generation,
              expectedPlaybackGeneration == playbackGeneration,
              expectedTransportGeneration == transportIntentGeneration,
              networkReloadRequiredTrackID == trackID else { return }

        await waitForTransitionCommit()
        guard !Task.isCancelled,
              requestGeneration == networkRecoveryTaskGeneration,
              pathGeneration == latestNetworkPathEvent.generation,
              expectedPlaybackGeneration == playbackGeneration,
              expectedTransportGeneration == transportIntentGeneration,
              networkReloadRequiredTrackID == trackID else { return }

        beginTransitionCommit()
        var ownsTransitionCommit = true
        defer {
            if ownsTransitionCommit {
                endTransitionCommit()
            }
        }

        // This is the same logical track, not a skip: preserve queue/index, stats and scrobble state.
        // The existing `.playing` callback consumes pendingRestoreInfo, seeks, then unmutes.
        playbackProgressTracker.breakContinuity()
        stopProgressTimer()
        stopPositionSaveTimer()
        cancelPendingPrefetch()
        cancelNetworkRecoveryValidation()
        engine.cancelPreload()

        let resumePosition = max(currentProgress, snapshot.position)
        pendingRestoreInfo = (seekTime: resumePosition, pause: false)
        if resumePosition > 1 {
            engine.volume = 0
            isMutedForRestore = true
        }
        currentSource = freshSource
        engine.applyReplayGain(dB: ReplayGainService.gainDB(track: track, config: snapshot.replayGainConfig))
        configureAudioSessionIfNeeded()
        let token = engine.play(
            trackID: trackID,
            url: freshSource.url,
            headers: freshSource.customHeaders
        )
        registerActiveEnginePlayback(
            token,
            playbackGeneration: expectedPlaybackGeneration,
            transportIntentGeneration: expectedTransportGeneration
        )
        networkRecoveryValidationToken = token
        engine.setTrackDuration(snapshot.duration)

        await MainActor.run {
            state.playbackState = .playing
            state.isPlaybackAvailable = true
            state.position = resumePosition
        }
        guard expectedPlaybackGeneration == playbackGeneration,
              expectedTransportGeneration == transportIntentGeneration else { return }
        startProgressTimer()
        startPositionSaveTimer()
        endTransitionCommit()
        ownsTransitionCommit = false
        await pushPositionSnapshot(rate: 1.0)
        Logger.player.info(
            "[NETWORK-RECOVERY] rebuild attempt=\(attempt, privacy: .public) track='\(trackID, privacy: .public)' at \(resumePosition, format: .fixed(precision: 1))s"
        )
    }

    // MARK: - Position save timer

    private func startPositionSaveTimer() {
        stopPositionSaveTimer()
        positionSaveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, let self else { break }
                await self.performPositionSaveTick()
            }
        }
    }

    private func performPositionSaveTick() async {
        guard !isRestoringSession else { return }
        // Position-only update — queue/track/mode already saved at each state change. Check the
        // actor-local seekability first (no MainActor hop): a non-seekable stream can't restore a
        // position, so skip the hop entirely rather than reading state only to discard it.
        guard engine.isSeekable else { return }
        let (isPlaying, pos) = await MainActor.run {
            (state.playbackState == .playing, state.position)
        }
        guard isPlaying else { return }
        await sessionService.savePosition(pos)
    }

    private func stopPositionSaveTimer() {
        positionSaveTask?.cancel()
        positionSaveTask = nil
    }

    // MARK: - Progress timer

    private func startProgressTimer() {
        stopProgressTimer()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self else { break }
                await self.performProgressTick()
            }
        }
    }

    private func performProgressTick() async {
        let progress = engine.progress
        let audioDuration = engine.duration
        let durationSnapshot = await MainActor.run {
            // Refine the duration BEFORE clamping the position against it. The engine's own
            // value lands as soon as the stream reports its length; clamping first pinned the
            // position for a tick against a metadata length already known to be wrong.
            let shouldRefineEngineDuration = audioDuration > state.duration + 0.5
            if shouldRefineEngineDuration {
                state.duration = audioDuration
            }
            // Never turn the playhead into a fake duration. If an estimate is too short,
            // growing duration to `progress` leaves the player permanently at -0:00 and makes
            // a seek-to-end target the current position. Keep both facts independently visible.
            state.position = max(progress, 0)
            return (
                trackID: state.currentTrack?.id,
                duration: state.duration,
                shouldRefineEngineDuration: shouldRefineEngineDuration
            )
        }
        if durationSnapshot.shouldRefineEngineDuration {
            engine.setTrackDuration(audioDuration)
        }
        if let trackID = durationSnapshot.trackID,
           progress > durationSnapshot.duration + 0.5 {
            logDurationMismatchIfNeeded(
                trackID: trackID,
                progress: progress,
                stateDuration: durationSnapshot.duration,
                engineDuration: audioDuration
            )
        }
        await accumulatePlaybackProgress(progress)
        await periodicNowPlayingPush(elapsed: progress)
        await checkScrobbleThreshold()
        await checkPrefetchThreshold()
    }

    private func stopProgressTimer() {
        progressTask?.cancel()
        progressTask = nil
    }

    private func logDurationMismatchIfNeeded(
        trackID: String,
        progress: Double,
        stateDuration: Double,
        engineDuration: Double
    ) {
        guard durationMismatchLoggedTrackID != trackID else { return }
        durationMismatchLoggedTrackID = trackID
        Logger.player.warning(
            "[DURATION] playhead exceeded advertised duration — track=\(trackID, privacy: .public) position=\(progress, format: .fixed(precision: 3))s stateDuration=\(stateDuration, format: .fixed(precision: 3))s engineDuration=\(engineDuration, format: .fixed(precision: 3))s"
        )
    }

    // MARK: - Scrobble

    /// Cancels any pending playing-now task. Called when switching tracks,
    /// switching to radio, or stopping. Safe to call when no task is scheduled.
    private func cancelPendingScrobble() {
        subsonicPlayingNowTask?.cancel()
        subsonicPlayingNowTask = nil
        playingNowTask?.cancel()
        playingNowTask = nil
    }

    private func checkScrobbleThreshold() async {
        guard let song = await MainActor.run(body: { state.currentTrack }) else { return }
        fireScrobbleIfThresholdMet(song: song)
    }

    // Synchronous split keeps the tracker's one-shot threshold mutation free of reentrancy.
    private func fireScrobbleIfThresholdMet(song: DisplayableSong) {
        let songId = song.id
        guard let startDate = playbackProgressTracker.scrobbleStartDateIfThresholdMet(
            trackDuration: song.duration
        ) else {
            return
        }
        Task { [libraryService] in
            await libraryService.scrobble(songId: songId, submission: true)
        }
        Task { [listenBrainzService] in
            await listenBrainzService.notifyScrobbleThreshold(song: song, startDate: startDate)
        }
    }

    private func cancelPendingCacheDownload() {
        cacheDownloadTask?.cancel()
        cacheDownloadTask = nil
    }

    // MARK: - Crossfade prefetch

    private func cancelPendingPrefetch() {
        prefetchGeneration &+= 1
        prefetchScheduled = false
    }

    nonisolated static func shouldSchedulePrefetch(crossfadeDuration: Double, remaining: Double) -> Bool {
        remaining <= max(0, crossfadeDuration) + 15.0
    }

    nonisolated static func shouldProtectTransitionFromCaching(crossfadeDuration: Double, remaining: Double) -> Bool {
        remaining <= max(0, crossfadeDuration) + 30.0
    }

    nonisolated static func effectiveCrossfadeOverlap(
        duration: Double,
        disableForGapless: Bool,
        isGaplessPair: Bool
    ) -> Double {
        guard duration > 0 else { return 0 }
        return disableForGapless && isGaplessPair ? 0 : duration
    }

    private func checkPrefetchThreshold() async {
        guard !prefetchScheduled else { return }
        // Snapshot only the scalars each tick — never copy the whole `state.queue` array (it can be large
        // and this runs every 500ms). The next-song element is read on MainActor only when we actually
        // proceed, in a single hop alongside the server id (also trimming one MainActor round-trip).
        let (currentIndex, duration, position, hasNextTrack, repeatMode) = await MainActor.run {
            let nextIndex = state.currentIndex + 1
            return (
                state.currentIndex,
                state.duration,
                state.position,
                state.queue.indices.contains(nextIndex),
                state.repeatMode
            )
        }
        guard duration > 0, hasNextTrack, repeatMode != .one else { return }
        let remaining = duration - position
        if cacheDownloadTask != nil,
           PlayerService.shouldProtectTransitionFromCaching(
               crossfadeDuration: crossfadeConfig.duration,
               remaining: remaining
           ) {
            Logger.player.debug(
                "[CACHE] cancelling background download before standby preload (remaining=\(String(format: "%.1f", remaining))s)"
            )
            cancelPendingCacheDownload()
        }
        guard PlayerService.shouldSchedulePrefetch(crossfadeDuration: crossfadeConfig.duration, remaining: remaining) else { return }

        let nextIndex = currentIndex + 1
        let resolved: (nextSong: DisplayableSong, serverId: UUID)? = await MainActor.run {
            guard state.queue.indices.contains(nextIndex),
                  let serverId = serverService.state.activeServer?.id else { return nil }
            return (state.queue[nextIndex], serverId)
        }
        guard let resolved else { return }

        prefetchScheduled = true
        Logger.player.debug("[PREFETCH] scheduling standby preload for '\(resolved.nextSong.title, privacy: .public)' (remaining=\(String(format: "%.1f", remaining))s)")
        let generation = playbackGeneration
        let requestedPrefetchGeneration = prefetchGeneration
        await preloadNextForGapless(
            nextSong: resolved.nextSong,
            serverId: resolved.serverId,
            generation: generation,
            prefetchGeneration: requestedPrefetchGeneration
        )
    }

    /// Pre-buffers the next track in the engine for a seamless hand-off. The crossfade itself is
    /// delegated here (duration > 0 = engine-blended overlap; gapless pairs stay at 0 when the user
    /// asked crossfade to stand aside for them). Repeat-one always skips: the queue's next is not
    /// what actually plays next.
    private func preloadNextForGapless(
        nextSong: DisplayableSong,
        serverId: UUID,
        generation: UInt64,
        prefetchGeneration: UInt64
    ) async {
        let songId = nextSong.id
        guard await isPrefetchContextValid(
            songId: songId,
            serverId: serverId,
            generation: generation,
            prefetchGeneration: prefetchGeneration
        ) else { return }
        let repeatMode = await MainActor.run { state.repeatMode }
        guard repeatMode != .one else { return }

        let isPair = await isNextGaplessPair(songId: songId)
        let overlap = Self.effectiveCrossfadeOverlap(
            duration: crossfadeConfig.duration,
            disableForGapless: crossfadeConfig.disableForGapless,
            isGaplessPair: isPair
        )

        guard let source = try? await mediaResolver.resolve(songId: songId, serverId: serverId) else {
            Logger.player.warning("[CROSSFADE] unable to resolve next track '\(songId, privacy: .public)' for preload")
            return
        }
        let trim = await gaplessTrim(nextSongId: songId, serverId: serverId, isPair: isPair, overlap: overlap)
        guard await isPrefetchContextValid(
            songId: songId,
            serverId: serverId,
            generation: generation,
            prefetchGeneration: prefetchGeneration
        ) else {
            Logger.player.debug("[PREFETCH] discarded stale preload for '\(songId, privacy: .public)'")
            return
        }
        let replayGainConfig = await MainActor.run { replayGainSettings.config }
        guard await isPrefetchContextValid(
            songId: songId,
            serverId: serverId,
            generation: generation,
            prefetchGeneration: prefetchGeneration
        ) else {
            Logger.player.debug("[PREFETCH] discarded stale ReplayGain preload for '\(songId, privacy: .public)'")
            return
        }
        let replayGainDB = ReplayGainService.gainDB(track: nextSong, config: replayGainConfig)
        engine.setTrackEndTrim(trim.leadOut)
        engine.preloadNext(
            trackID: songId,
            url: source.url,
            headers: source.customHeaders,
            crossfadeDuration: overlap,
            leadInTrim: trim.leadIn,
            replayGainDB: replayGainDB
        )
        Logger.player.info(
            "[CROSSFADE] preloaded next='\(songId, privacy: .public)' configured=\(self.crossfadeConfig.duration, format: .fixed(precision: 1))s gaplessPair=\(isPair, privacy: .public) overlap=\(overlap, format: .fixed(precision: 1))s replayGain=\(replayGainDB, format: .fixed(precision: 2))dB trimIn=\(trim.leadIn, format: .fixed(precision: 3))s trimOut=\(trim.leadOut, format: .fixed(precision: 3))s"
        )
    }

    private func isPrefetchContextValid(
        songId: String,
        serverId: UUID,
        generation: UInt64,
        prefetchGeneration: UInt64
    ) async -> Bool {
        guard generation == playbackGeneration,
              prefetchGeneration == self.prefetchGeneration,
              !Task.isCancelled else { return false }
        return await MainActor.run {
            let nextIndex = state.currentIndex + 1
            return serverService.state.activeServer?.id == serverId
                && state.queue.indices.contains(nextIndex)
                && state.queue[nextIndex].id == songId
                && state.currentTrack != nil
        }
    }

    /// Silence to cut at the seam between two consecutive album tracks.
    ///
    /// Only for a real butt-splice: a crossfade needs the outgoing tail to fade into, and two tracks
    /// that are not album neighbours were never meant to run together. Downloaded files only —
    /// measuring means decoding, and doing that over the network for a few milliseconds of silence
    /// is not a trade worth making.
    private func gaplessTrim(
        nextSongId: String,
        serverId: UUID,
        isPair: Bool,
        overlap: Double
    ) async -> GaplessTrim {
        guard isPair, overlap == 0,
              let nextURL = await downloadService.downloadedURL(forSongId: nextSongId, serverId: serverId),
              let currentId = await MainActor.run(body: { state.currentTrack?.id }),
              let currentURL = await downloadService.downloadedURL(forSongId: currentId, serverId: serverId)
        else { return .none }

        async let incoming = GaplessTrimAnalyzer.measure(url: nextURL)
        async let outgoing = GaplessTrimAnalyzer.measure(url: currentURL)
        let (headTrim, tailTrim) = await (incoming, outgoing)
        return GaplessTrim(leadIn: headTrim.leadIn, leadOut: tailTrim.leadOut)
    }

    /// True when the current track and the queued `songId` form a gapless pair (same album,
    /// consecutive tracks) — mirrors the crossfade fade-out skip.
    private func isNextGaplessPair(songId: String) async -> Bool {
        await MainActor.run {
            let nextIndex = state.currentIndex + 1
            guard let current = state.currentTrack,
                  state.queue.indices.contains(nextIndex) else { return false }
            let next = state.queue[nextIndex]
            guard next.id == songId else { return false }
            return PlayerService.isGaplessPair(
                currentAlbumId: current.albumId,
                currentTrackNumber: current.trackNumber,
                nextAlbumId: next.albumId,
                nextTrackNumber: next.trackNumber
            )
        }
    }

    // MARK: - Gapless pairing

    /// Returns true when the current and next track form a gapless pair (same album, consecutive track numbers).
    /// Nil albumId or track number → not a pair, so crossfade proceeds.
    nonisolated static func isGaplessPair(
        currentAlbumId: String?,
        currentTrackNumber: Int?,
        nextAlbumId: String?,
        nextTrackNumber: Int?
    ) -> Bool {
        guard let cAlbum = currentAlbumId,
              let nAlbum = nextAlbumId,
              let cTrack = currentTrackNumber,
              let nTrack = nextTrackNumber else { return false }
        return cAlbum == nAlbum && nTrack == cTrack + 1
    }

    /// Returns true when the route outputs represent a personal listening device whose
    /// disconnection must auto-pause playback (never continue on the built-in speaker).
    /// Includes AirPlay/CarPlay so their disconnects keep today's pause behavior.
    nonisolated static func isPersonalAudioRoute(portTypes: [AVAudioSession.Port]) -> Bool {
        let personal: Set<AVAudioSession.Port> = [
            .headphones, .bluetoothA2DP, .bluetoothLE, .bluetoothHFP, .airPlay, .carAudio
        ]
        return portTypes.contains(where: { personal.contains($0) })
    }

    /// An ambiguous route notification must never manufacture a user pause. Suspend only when a
    /// known personal output disappeared and iOS actually fell back to a non-personal route.
    nonisolated static func shouldSuspendForRouteDisconnect(
        previous: [AVAudioSession.Port],
        current: [AVAudioSession.Port]
    ) -> Bool {
        !previous.isEmpty
            && isPersonalAudioRoute(portTypes: previous)
            && !isPersonalAudioRoute(portTypes: current)
    }

    /// Automatic route recovery is allowed only on a personal output compatible with the one that
    /// disappeared. An explicit Play remains available if the user deliberately wants the speaker.
    nonisolated static func canResumeOnPersonalRoute(
        expected: [AVAudioSession.Port],
        current: [AVAudioSession.Port]
    ) -> Bool {
        guard isPersonalAudioRoute(portTypes: current) else { return false }
        let expectedPersonal = expected.filter { isPersonalAudioRoute(portTypes: [$0]) }
        return expectedPersonal.isEmpty || current.contains(where: expectedPersonal.contains)
    }

    // MARK: - Play-time accumulator

    private func accumulatePlaybackProgress(_ progress: TimeInterval) async {
        let shouldCount = await MainActor.run {
            state.playbackState == .playing && !state.isLiveStream
        }
        playbackProgressTracker.record(progress: progress, isPlaying: shouldCount)
    }

    // MARK: - Stats recording

    private func recordCurrentTrackPlayback(trigger: String = "unknown") async {
        guard let song = await MainActor.run(body: { state.currentTrack }) else { return }
        guard let serverId = await MainActor.run(body: { serverService.state.activeServer?.id }) else { return }
        await accumulatePlaybackProgress(engine.progress)
        let trackDuration = await MainActor.run { state.duration }
        guard let dto = playbackProgressTracker.playbackEvent(
            song: song,
            trackDuration: trackDuration,
            wasCompleted: wasTrackCompletedNaturally,
            serverId: serverId
        ) else {
            let durationListened = playbackProgressTracker.accumulatedTime
            Logger.player.debug("[STATS] Skip — durationListened=\(durationListened, format: .fixed(precision: 1))s < 30s for '\(song.title, privacy: .public)'")
            return
        }

        await statsService.recordPlayback(dto, trigger: trigger)
        let artistIdForLog = song.artistId ?? "nil"
        let durationForLog = String(format: "%.1f", dto.durationListened)
        let trackDurationForLog = String(format: "%.1f", trackDuration)
        Logger.player.debug(
            "[STATS] Recorded: trigger=\(trigger, privacy: .public) trackId=\(song.id, privacy: .public) artistId=\(artistIdForLog, privacy: .public) durationListened=\(durationForLog, privacy: .public)s trackDuration=\(trackDurationForLog, privacy: .public)s startedAt=\(dto.timestamp, privacy: .public) completed=\(dto.wasCompleted, privacy: .public)"
        )
    }

    // MARK: - End of track

    func handleEndOfTrack(playbackToken: AudioEnginePlaybackToken) async {
        guard isCurrentEngineEvent(playbackToken) else {
            Logger.player.debug("[END-OF-TRACK] ignored stale engine callback")
            return
        }
        let isQueuePlayback = await MainActor.run { !state.isLiveStream }
        guard isCurrentEngineEvent(playbackToken) else { return }
        guard isQueuePlayback else {
            Logger.player.debug("[END-OF-TRACK] ignored — live stream mode")
            return
        }
        guard !isRestoringSession else {
            Logger.player.warning("[END-OF-TRACK] suppressed — session restore in progress")
            return
        }
        guard endOfTrackEventsInProgress.insert(playbackToken).inserted else {
            Logger.player.warning("[END-OF-TRACK] already handling — skipping duplicate")
            return
        }
        defer { endOfTrackEventsInProgress.remove(playbackToken) }
        let transition = await queueTransitionSnapshot()
        guard isCurrentEngineEvent(playbackToken) else { return }
        let plan = PlaybackTransitionPlanner.plan(
            for: .trackEnded,
            snapshot: transition.planner
        )
        do {
            try await executeTransitionPlan(plan, queue: transition.queue)
        } catch {
            Logger.player.error("[TRANSITION] handleEndOfTrack failed: \(error, privacy: .public)")
        }
    }

    /// The queue reached its end with repeat off. Stop cleanly with no muted "parking" play of track 1.
    /// The queue + current index/track are kept and the position is parked at the end; the transition planner
    /// makes `resume()` restart the queue from track 0.
    private func pauseAtEndOfQueue() async {
        // The transition plan set the completion attribution before entering this method.
        await recordCurrentTrackPlayback(trigger: "end_of_queue")
        wasTrackCompletedNaturally = false
        playbackProgressTracker.reset()

        stopProgressTimer()
        stopPositionSaveTimer()
        // The engine is at EOF — stop it (NO parking play) and release the session.
        engine.stop()
        activeEnginePlayback = nil
        sessionActivationRetryTask?.cancel()
        sessionActivationRetryTask = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        pendingRestoreInfo = nil
        stoppedAtEndOfQueue = true

        Logger.player.info("[PLAYBACK] End of queue (repeat off) — stopped cleanly at end; resume restarts from track 0")

        let duration = await MainActor.run { state.duration }
        await MainActor.run {
            state.playbackState = .paused
            state.position = duration   // park at the very end of the still-selected last track
        }
        await pushPositionSnapshot(rate: 0)
        await saveSession()
    }

    // MARK: - Delegate callbacks

    /// Called by the engine bridge when the low-level playback state changes.
    func handleEngineState(
        _ newState: AudioEngineState,
        playbackToken: AudioEnginePlaybackToken
    ) async {
        guard isCurrentEngineEvent(playbackToken) else { return }
        switch newState {
        case .playing:
            if let info = pendingRestoreInfo {
                pendingRestoreInfo = nil
                // Seek while the engine is running. AVPlayer may still accept the request while its
                // seekable ranges are being populated, so isSeekable is diagnostic rather than a gate.
                if info.seekTime > 1 {
                    let succeeded = await engine.seek(to: info.seekTime)
                    guard isCurrentEngineEvent(playbackToken) else { return }
                    Logger.player.info(
                        "[RESTORE] seek target=\(info.seekTime, format: .fixed(precision: 3))s completed=\(succeeded, privacy: .public) landed=\(self.engine.progress, format: .fixed(precision: 3))s"
                    )
                    playbackProgressTracker.setBaseline(engine.progress)
                }
                if info.pause {
                    // Give processSeekTime() 150 ms to clear the render buffer and reopen
                    // the HTTP connection at the correct byte offset before pausing.
                    // Stored so resume() can cancel the deferred pause via task.cancel().
                    restorePauseTask = Task {
                        try? await Task.sleep(for: .milliseconds(150))
                        guard !Task.isCancelled, self.isCurrentEngineEvent(playbackToken) else { return }
                        self.restorePauseTask = nil
                        self.engine.pause()
                        self.engine.volume = self.restoredVolume
                        self.isMutedForRestore = false
                        await MainActor.run { self.state.playbackState = .paused }
                        self.stopProgressTimer()
                        self.isRestoringSession = false
                        Logger.player.info("[RESTORE] seek landed — paused at \(self.engine.progress, format: .fixed(precision: 1))s")
                    }
                    break
                }
                if isMutedForRestore {
                    engine.volume = restoredVolume
                    isMutedForRestore = false
                }
                isRestoringSession = false
            } else {
                playbackProgressTracker.establishBaselineIfNeeded(engine.progress)
            }

            if networkRecoveryValidationToken == playbackToken {
                let trackID = await MainActor.run { state.currentTrack?.id }
                guard isCurrentEngineEvent(playbackToken) else { return }
                if let trackID, networkReloadRequiredTrackID == trackID {
                    armNetworkRecoveryValidation(
                        playbackToken: playbackToken,
                        trackID: trackID
                    )
                }
            }
        case .buffering, .paused:
            playbackProgressTracker.breakContinuity()
            if newState == .paused {
                await resumeAfterNetworkPauseIfNeeded(playbackToken: playbackToken)
            }
            await armRecoveryForUnexpectedEngineStall(playbackToken: playbackToken)
        case .stopped:
            playbackProgressTracker.breakContinuity()
        case .error:
            if networkRecoveryValidationToken == playbackToken {
                cancelNetworkRecoveryValidation()
            }
            let engineSnapshot = await MainActor.run {
                (isLive: state.isLiveStream, trackID: state.currentTrack?.id)
            }
            guard isCurrentEngineEvent(playbackToken) else { return }
            let liveStationName: String?
            if engineSnapshot.isLive {
                liveStationName = await MainActor.run { state.currentRadio?.name ?? "" }
                guard isCurrentEngineEvent(playbackToken) else { return }
            } else {
                liveStationName = nil
            }
            if currentSourceIsRemoteStream, let trackID = engineSnapshot.trackID {
                networkReloadRequiredTrackID = trackID
            }
            playbackProgressTracker.breakContinuity()
            stopProgressTimer()
            stopPositionSaveTimer()
            cancelPendingCacheDownload()
            cancelPendingPrefetch()
            engine.stop()
            activeEnginePlayback = nil
            Logger.player.error("[PLAYER] engine entered error state")
            if let liveStationName {
                await handleLiveStreamFailure(stationName: liveStationName, error: nil)
            } else {
                await MainActor.run { state.playbackState = .error(.timeout) }
                if let trackID = networkReloadRequiredTrackID,
                   latestNetworkPathEvent.isOnline {
                    armNetworkRecoveryProbe(
                        trackID: trackID,
                        delay: .seconds(2),
                        requireStall: false
                    )
                }
            }
        }
    }

    /// AVPlayer can report `.paused` for a remote item while its connection is being rebound to a
    /// newly available network interface. The engine's playback intent is still active in that case,
    /// so resume immediately and let the recovery probe handle a genuinely unavailable stream.
    /// Explicit user pauses are excluded because they update `state.playbackState` before the engine
    /// callback reaches this actor.
    private func resumeAfterNetworkPauseIfNeeded(
        playbackToken: AudioEnginePlaybackToken
    ) async {
        guard currentSourceIsRemoteStream,
              latestNetworkPathEvent.isOnline else { return }
        let snapshot = await MainActor.run {
            (
                playbackState: state.playbackState,
                trackID: state.currentTrack?.id,
                duration: state.duration
            )
        }
        guard isCurrentEngineEvent(playbackToken),
              snapshot.playbackState == .playing,
              let trackID = snapshot.trackID,
              networkReloadRequiredTrackID == trackID else { return }

        let progress = engine.progress
        if snapshot.duration > 0,
           progress >= snapshot.duration - 1.5 {
            // A pause at the end belongs to the normal queue transition, not network recovery.
            return
        }

        engine.resume()
        Logger.player.info(
            "[NETWORK-RECOVERY] resumed transient pause track='\(trackID, privacy: .public)' at \(progress, format: .fixed(precision: 1))s"
        )
    }

    private func armRecoveryForUnexpectedEngineStall(
        playbackToken: AudioEnginePlaybackToken
    ) async {
        guard currentSourceIsRemoteStream,
              latestNetworkPathEvent.isOnline else { return }
        let snapshot = await MainActor.run {
            (trackID: state.currentTrack?.id, playbackState: state.playbackState)
        }
        guard isCurrentEngineEvent(playbackToken),
              snapshot.playbackState == .playing,
              let trackID = snapshot.trackID,
              networkReloadRequiredTrackID == trackID else { return }
        armNetworkRecoveryProbe(trackID: trackID, delay: .seconds(2), requireStall: true)
    }

    /// Called by the engine bridge on unexpected errors.
    func handleEngineError(
        _ message: String,
        playbackToken: AudioEnginePlaybackToken
    ) async {
        guard isCurrentEngineEvent(playbackToken) else { return }
        if networkRecoveryValidationToken == playbackToken {
            cancelNetworkRecoveryValidation()
        }
        let engineSnapshot = await MainActor.run {
            (isLive: state.isLiveStream, trackID: state.currentTrack?.id)
        }
        guard isCurrentEngineEvent(playbackToken) else { return }
        let liveStationName: String?
        if engineSnapshot.isLive {
            liveStationName = await MainActor.run { state.currentRadio?.name ?? "" }
            guard isCurrentEngineEvent(playbackToken) else { return }
        } else {
            liveStationName = nil
        }
        if currentSourceIsRemoteStream, let trackID = engineSnapshot.trackID {
            networkReloadRequiredTrackID = trackID
        }
        playbackProgressTracker.breakContinuity()
        stopProgressTimer()
        stopPositionSaveTimer()
        cancelPendingCacheDownload()
        cancelPendingPrefetch()
        engine.stop()
        activeEnginePlayback = nil
        Logger.player.error("[PLAYER] engine unexpected error: \(message, privacy: .public)")
        if let liveStationName {
            await handleLiveStreamFailure(stationName: liveStationName, error: nil)
        } else {
            await MainActor.run { state.playbackState = .error(.timeout) }
            if let trackID = networkReloadRequiredTrackID,
               latestNetworkPathEvent.isOnline {
                armNetworkRecoveryProbe(
                    trackID: trackID,
                    delay: .seconds(2),
                    requireStall: false
                )
            }
        }
    }

    // MARK: - Next track artwork pre-load

    private func preloadNextTrackArtwork() {
        Task {
            let (queue, currentIndex) = await MainActor.run { (state.queue, state.currentIndex) }
            let nextIndex = currentIndex + 1
            guard nextIndex < queue.count else { return }
            let nextTrack = queue[nextIndex]
            await artworkImageCache.load(coverArtId: nextTrack.coverArtId ?? nextTrack.id)
        }
    }

    // MARK: - Artwork / NowPlaying helpers

    private func resolveArtworkURL(for song: DisplayableSong) async -> URL? {
        guard let client = try? await serverService.makeSwiftSonicClient() else { return nil }
        let artId = song.coverArtId ?? song.id
        return client.coverArtURL(id: artId, size: 600)
    }

    // MARK: - Cache download helpers

    private func cacheStreamAfterDelay(
        songId: String,
        serverId: UUID,
        streamURL: URL,
        customHeaders: [String: String],
        allowCellular: Bool,
        generation: UInt64
    ) async {
        defer {
            if generation == playbackGeneration {
                cacheDownloadTask = nil
            }
        }

        do {
            try await Task.sleep(for: .seconds(30))
        } catch {
            return
        }
        guard !Task.isCancelled, generation == playbackGeneration else { return }
        if await audioStreamCache.cachedURL(forSongId: songId, serverId: serverId) != nil { return }
        if await downloadService.isDownloaded(songId: songId, serverId: serverId) { return }

        let isExpensive = await MainActor.run { serverService.state.isExpensive }
        if isExpensive && !allowCellular {
            Logger.player.debug("Cache skipped — cellular for '\(songId, privacy: .public)'")
            return
        }

        do {
            try await downloadAndCache(
                songId: songId,
                serverId: serverId,
                streamURL: streamURL,
                customHeaders: customHeaders,
                using: cacheSession
            )
        } catch {
            if Task.isCancelled {
                Logger.player.debug("Cache download cancelled for '\(songId, privacy: .public)'")
            } else {
                Logger.player.debug("Cache download failed for '\(songId, privacy: .public)': \(error, privacy: .public)")
            }
        }
    }

    /// Downloads the track from its stream URL and stores it in AudioStreamCache.
    /// Uses URLSession.download for disk-streaming efficiency (temporary file → cache file).
    private func downloadAndCache(
        songId: String,
        serverId: UUID,
        streamURL: URL,
        customHeaders: [String: String],
        using session: URLSession
    ) async throws {
        var request = URLRequest(url: streamURL)
        for (key, value) in customHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (tempURL, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            struct CacheDownloadError: Error, Sendable { let statusCode: Int }
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw CacheDownloadError(statusCode: code)
        }

        // Never commit a poisoned payload (Subsonic error-as-200 envelope, empty or
        // truncated body) — a broken cache file plays as silence through FileAudioSource.
        try AudioResponseValidator.validate(fileAt: tempURL, response: response, songId: songId, logger: Logger.cache)

        let ext = streamURL.pathExtension
        let mimeType = response.mimeType ?? (ext.isEmpty ? "audio/mpeg" : "audio/\(ext)")
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? Int64) ?? 0

        _ = try await audioStreamCache.store(
            fileAt: tempURL,
            forSongId: songId,
            serverId: serverId,
            mimeType: mimeType
        )

        Logger.player.info("Cached '\(songId, privacy: .public)' from stream (\(fileSize) bytes, \(mimeType, privacy: .public))")
    }

    // MARK: - NowPlaying position push

    /// Pushes a position-only snapshot when track metadata hasn't changed (pause/resume/seek).
    private func pushPositionSnapshot(rate: Float? = nil) async {
        let (track, position, playbackState, duration) = await MainActor.run {
            (state.currentTrack, state.position, state.playbackState, state.duration)
        }
        guard let track else { return }

        let resolvedRate: Float
        if let rate {
            resolvedRate = rate
        } else if case .playing = playbackState {
            resolvedRate = 1.0
        } else {
            resolvedRate = 0.0
        }

        let snapshot = NowPlayingSnapshot(
            title: track.title,
            artist: track.artist,
            album: track.albumName,
            duration: duration,
            position: max(position, 0),
            playbackRate: resolvedRate,
            artworkURL: nil,
            artworkHeaders: [:],
            coverArtId: nil,
            isLiveStream: false,
            radioStationName: nil,
            songId: track.id
        )
        await nowPlayingService?.update(with: snapshot)
    }

    /// Called from the progress timer to keep MPNowPlayingInfoCenter in sync.
    /// Guards ensure we only push during live playback — not during transitions, live streams,
    /// or when elapsed is out of range — so we never send a stale or impossible position.
    private func periodicNowPlayingPush(elapsed: TimeInterval) async {
        let (playbackState, duration, isLiveStream, songId) = await MainActor.run {
            (state.playbackState, state.duration, state.isLiveStream, state.currentTrack?.id)
        }
        guard case .playing = playbackState, !isLiveStream, let songId else { return }
        guard elapsed >= 0, duration > 0 else { return }
        if let last = lastNowPlayingPushElapsed,
           elapsed >= last,
           elapsed - last < 1.0 {
            return
        }
        lastNowPlayingPushElapsed = elapsed
        await nowPlayingService?.pushPosition(
            elapsed: elapsed,
            rate: 1.0,
            duration: duration,
            songId: songId
        )
    }

    // nonisolated: safe — only called during app termination
    nonisolated func stopAudioEngineSync() {
        engine.stop()
    }
}

// MARK: - iOS Audio Session

extension PlayerService {
    /// Sets the category (once) and activates the session.
    ///
    /// No category options, deliberately. `.allowAirPlay` and `.allowBluetoothHFP` are both documented
    /// as settable only on `.playAndRecord` (HFP also on `.record`); pairing either with `.playback`
    /// made `setCategory` fail with -50 (paramErr) on every call. Because the failure threw before
    /// `audioSessionConfigured = true`, the flag never latched, the category was never applied, and
    /// `setActive` below was never reached — playback only started once the retry fired 0.5 s later,
    /// which is the delay felt on every Play. Neither option is needed: `.playback` already routes to
    /// AirPlay and to Bluetooth A2DP.
    private func activateAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        if !audioSessionConfigured {
            try session.setCategory(.playback)
            audioSessionConfigured = true
        }
        // Always re-activate — iOS may have deactivated the session during a background interruption
        // (phone call, Siri, other audio app) even after a successful initial setup. Without this,
        // resume() silently fails on the lock screen.
        try session.setActive(true)
    }

    private func retryAudioSessionActivation() {
        do {
            try activateAudioSession()
        } catch {
            Logger.player.error("AVAudioSession retry failed: \(error, privacy: .public)")
        }
    }

    func configureAudioSessionIfNeeded() {
        do {
            try activateAudioSession()
        } catch let error as NSError {
            // The retry re-runs the CATEGORY too. The old one re-tried activation alone, so a failed
            // setCategory left the app on the default category for the whole session — no guaranteed
            // background audio, silenced by the ring switch. `configured` says which call failed.
            Logger.player.warning(
                "AVAudioSession configuration failed (code \(error.code, privacy: .public), configured=\(self.audioSessionConfigured, privacy: .public)) — retrying in 0.5s"
            )
            sessionActivationRetryTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(0.5))
                guard !Task.isCancelled else { return }
                await self?.retryAudioSessionActivation()
            }
        }
        if interruptionObserver == nil {
            interruptionObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] notification in
                guard let self, let event = AudioSessionInterruptionEvent(notification: notification) else {
                    return
                }
                Task { await self.handleAudioSessionInterruption(event) }
            }
        }
        if routeChangeObserver == nil {
            routeChangeObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] notification in
                guard let self else { return }
                guard let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                      let changeReason = AVAudioSession.RouteChangeReason(rawValue: reason) else { return }
                // AVAudioSessionRouteDescription is not Sendable — extract value-only route data
                // here on the main queue before hopping to the actor.
                let previousOutputs = (notification.userInfo?[AVAudioSessionRouteChangePreviousRouteKey]
                    as? AVAudioSessionRouteDescription)?.outputs.map {
                        AudioRouteOutputSnapshot(uid: $0.uid, portType: $0.portType)
                    } ?? []
                Task {
                    await self.handleRouteChange(
                        changeReason,
                        previousRouteOutputs: previousOutputs
                    )
                }
            }
        }
    }

    private func handleAudioSessionInterruption(_ event: AudioSessionInterruptionEvent) async {
        switch event {
        case .began(let routeDisconnected):
            isAudioSessionInterrupted = true
            await suspendPlaybackForSystem(
                reason: "interruption",
                requiresPersonalRoute: routeDisconnected,
                expectedRouteOutputs: []
            )
            Logger.player.info(
                "[INTERRUPTION] began routeDisconnect=\(routeDisconnected, privacy: .public)"
            )

        case .ended(let shouldResume):
            isAudioSessionInterrupted = false
            let requiresPersonalRoute = pendingSystemResume?.requiresPersonalRoute == true
            Logger.player.info(
                "[INTERRUPTION] ended shouldResume=\(shouldResume, privacy: .public) requiresPersonalRoute=\(requiresPersonalRoute, privacy: .public)"
            )
            if shouldResume || requiresPersonalRoute {
                await resumeSystemPauseIfEligible(trigger: "interruption-ended")
            } else {
                pendingSystemResume = nil
                Logger.player.info("[INTERRUPTION] ended — staying paused")
            }
        }
    }

    // internal: accessible from tests via @testable import
    func handleRouteChange(
        _ reason: AVAudioSession.RouteChangeReason,
        previousOutputs: [AVAudioSession.Port] = []
    ) async {
        await handleRouteChange(
            reason,
            previousRouteOutputs: previousOutputs.map {
                AudioRouteOutputSnapshot(uid: "", portType: $0)
            }
        )
    }

    private func handleRouteChange(
        _ reason: AVAudioSession.RouteChangeReason,
        previousRouteOutputs: [AudioRouteOutputSnapshot]
    ) async {
        let currentOutputs = currentAudioRouteOutputs()
        let previousTypes = previousRouteOutputs.map(\.portType)
        let currentTypes = currentOutputs.map(\.portType)
        let outputDescription = currentTypes.map(\.rawValue).joined(separator: ",")
        Logger.player.info(
            "[ROUTE] routeChange reason=\(reason.logDescription, privacy: .public) outputs=[\(outputDescription, privacy: .public)]"
        )

        switch reason {
        case .oldDeviceUnavailable:
            guard PlayerService.shouldSuspendForRouteDisconnect(
                previous: previousTypes,
                current: currentTypes
            ) else {
                Logger.player.info(
                    "[ROUTE] ignored ambiguous/non-personal disconnect previousCount=\(previousTypes.count, privacy: .public)"
                )
                break
            }
            await suspendPlaybackForSystem(
                reason: "personal-route-disconnect",
                requiresPersonalRoute: true,
                expectedRouteOutputs: previousRouteOutputs
            )

        case .newDeviceAvailable, .routeConfigurationChange, .wakeFromSleep:
            do {
                try activateAudioSession()
            } catch {
                Logger.player.warning(
                    "[ROUTE] audio-session activation failed during route recovery: \(error, privacy: .public)"
                )
            }
            await resumeSystemPauseIfEligible(trigger: reason.logDescription)

        default:
            break
        }
    }

    private func currentAudioRouteOutputs() -> [AudioRouteOutputSnapshot] {
        AVAudioSession.sharedInstance().currentRoute.outputs.map {
            AudioRouteOutputSnapshot(uid: $0.uid, portType: $0.portType)
        }
    }

    private func suspendPlaybackForSystem(
        reason: String,
        requiresPersonalRoute: Bool,
        expectedRouteOutputs: [AudioRouteOutputSnapshot]
    ) async {
        let snapshot = await MainActor.run {
            (trackID: state.currentTrack?.id, playbackState: state.playbackState)
        }

        if var pending = pendingSystemResume,
           pending.playbackGeneration == playbackGeneration,
           pending.transportIntentGeneration == transportIntentGeneration,
           pending.trackID == snapshot.trackID {
            pending.requiresPersonalRoute = pending.requiresPersonalRoute || requiresPersonalRoute
            pending.expectedPersonalRouteUIDs.formUnion(
                expectedRouteOutputs
                    .filter { PlayerService.isPersonalAudioRoute(portTypes: [$0.portType]) }
                    .map(\.uid)
                    .filter { !$0.isEmpty }
            )
            pending.expectedPersonalPortTypes.formUnion(
                expectedRouteOutputs
                    .map(\.portType)
                    .filter { PlayerService.isPersonalAudioRoute(portTypes: [$0]) }
            )
            pendingSystemResume = pending
        } else {
            pendingSystemResume = nil
            guard snapshot.playbackState == .playing, let trackID = snapshot.trackID else { return }
            pendingSystemResume = PendingSystemResume(
                trackID: trackID,
                playbackGeneration: playbackGeneration,
                transportIntentGeneration: transportIntentGeneration,
                startedAt: Date(),
                requiresPersonalRoute: requiresPersonalRoute,
                expectedPersonalRouteUIDs: Set(
                    expectedRouteOutputs
                        .filter { PlayerService.isPersonalAudioRoute(portTypes: [$0.portType]) }
                        .map(\.uid)
                        .filter { !$0.isEmpty }
                ),
                expectedPersonalPortTypes: Set(
                    expectedRouteOutputs
                        .map(\.portType)
                        .filter { PlayerService.isPersonalAudioRoute(portTypes: [$0]) }
                )
            )
        }

        guard snapshot.playbackState == .playing else { return }
        playbackProgressTracker.breakContinuity()
        engine.pause()
        await MainActor.run { state.playbackState = .paused }
        stopProgressTimer()
        stopPositionSaveTimer()
        await pushPositionSnapshot(rate: 0)
        await saveSession()
        Logger.player.info(
            "[AUDIO-INTENT] suspended origin=\(reason, privacy: .public) pendingResume=true"
        )
    }

    private func resumeSystemPauseIfEligible(trigger: String) async {
        guard !isAudioSessionInterrupted, let pending = pendingSystemResume else { return }

        guard Date().timeIntervalSince(pending.startedAt) <= Self.personalRouteReconnectGrace else {
            pendingSystemResume = nil
            Logger.player.info("[AUDIO-INTENT] system resume expired trigger=\(trigger, privacy: .public)")
            return
        }

        let snapshot = await MainActor.run {
            (trackID: state.currentTrack?.id, playbackState: state.playbackState)
        }
        guard pending.playbackGeneration == playbackGeneration,
              pending.transportIntentGeneration == transportIntentGeneration,
              pending.trackID == snapshot.trackID,
              snapshot.playbackState != .idle else {
            pendingSystemResume = nil
            return
        }

        if pending.requiresPersonalRoute {
            let currentOutputs = currentAudioRouteOutputs()
            let currentTypes = currentOutputs.map(\.portType)
            guard PlayerService.canResumeOnPersonalRoute(
                expected: Array(pending.expectedPersonalPortTypes),
                current: currentTypes
            ) else {
                Logger.player.info(
                    "[AUDIO-INTENT] waiting for personal route trigger=\(trigger, privacy: .public)"
                )
                return
            }

            if !pending.expectedPersonalRouteUIDs.isEmpty {
                let currentPersonalUIDs = Set(
                    currentOutputs
                        .filter { PlayerService.isPersonalAudioRoute(portTypes: [$0.portType]) }
                        .map(\.uid)
                )
                guard !pending.expectedPersonalRouteUIDs.isDisjoint(with: currentPersonalUIDs) else {
                    Logger.player.info(
                        "[AUDIO-INTENT] personal route differs from disconnected output — staying paused"
                    )
                    return
                }
            }
        }

        pendingSystemResume = nil
        Logger.player.info("[AUDIO-INTENT] automatic resume trigger=\(trigger, privacy: .public)")
        await resume()
    }
}

// MARK: - AudioEngineBridge

/// Bridges the neutral `AudioEngineDelegate` callbacks (on the engine's callback thread) onto the
/// `PlayerService` actor. The concrete engine already maps its own
/// callbacks into the neutral events.
private nonisolated final class WeakPlayerServiceBox {
    weak var service: PlayerService?
}

nonisolated final class AudioEngineBridge: AudioEngineDelegate, Sendable {
    private let service = Mutex(WeakPlayerServiceBox())

    func connect(to service: PlayerService) {
        self.service.withLock {
            $0.service = service
        }
    }

    func audioEngineDidChangeState(
        _ state: AudioEngineState,
        playbackToken: AudioEnginePlaybackToken
    ) {
        guard let service = currentService() else { return }
        Task { await service.handleEngineState(state, playbackToken: playbackToken) }
    }

    func audioEngineDidReachEndOfTrack(playbackToken: AudioEnginePlaybackToken) {
        guard let service = currentService() else { return }
        Task { await service.handleEndOfTrack(playbackToken: playbackToken) }
    }

    func audioEngineDidError(_ message: String, playbackToken: AudioEnginePlaybackToken) {
        guard let service = currentService() else { return }
        Task { await service.handleEngineError(message, playbackToken: playbackToken) }
    }

    private func currentService() -> PlayerService? {
        service.withLock { $0.service }
    }
}

// MARK: - iOS logging helpers (file-private)

private extension AVAudioSession.RouteChangeReason {
    nonisolated var logDescription: String {
        switch self {
        case .unknown: return "unknown"
        case .newDeviceAvailable: return "newDeviceAvailable"
        case .oldDeviceUnavailable: return "oldDeviceUnavailable"
        case .categoryChange: return "categoryChange"
        case .override: return "override"
        case .wakeFromSleep: return "wakeFromSleep"
        case .noSuitableRouteForCategory: return "noSuitableRouteForCategory"
        case .routeConfigurationChange: return "routeConfigurationChange"
        @unknown default: return "unknown(\(rawValue))"
        }
    }
}
