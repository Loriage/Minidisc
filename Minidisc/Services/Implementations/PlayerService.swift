// Minidisc — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftSonic
import OSLog

import AVFAudio

actor PlayerService: PlayerServiceProtocol {
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

    // The low-level audio engine (AVPlayer, injected by AppContainer). It has its own
    // internal queue and is Sendable, so it's reachable from nonisolated contexts (e.g. termination).
    private let engine: AudioEngine
    private let engineBridge: AudioEngineBridge
    private var progressTask: Task<Void, Never>?
    /// Pending seek + optional pause applied once the player first reaches `.playing`.
    /// Used for session restoration and end-of-queue rewind.
    private var pendingRestoreInfo: (seekTime: Double, pause: Bool)?
    /// Source of the currently playing track; kept for repeat-one replay.
    private var currentSource: MediaSource?
    private var liveStreamStallTask: Task<Void, Never>?

    private var audioSessionConfigured = false
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    /// Stored so pause()/stop() can cancel it before calling setActive(false),
    /// preventing a stale retry from reactivating the session after the user stops.
    private var sessionActivationRetryTask: Task<Void, Never>?
    /// True when the current interruption began because the output route was disconnected
    /// (AirPods in case). Per Apple guidance, never auto-resume after such an interruption
    /// — resuming would route playback to the built-in speaker.
    private var interruptionWasRouteDisconnect = false

    private var isHandlingEndOfTrack = false
    /// True when playback stopped cleanly at the END of the queue (repeat off). `resume()` reads this to restart
    /// from track 0 instead of replaying the last track (which would hit EOF and re-stop — the mini-loop).
    /// Cleared by any real playback start (`play`).
    private var stoppedAtEndOfQueue = false
    /// True during the URL-resolution phase of session restore (prepareCurrentTrackForRestoration).
    /// Blocks handleEndOfTrack() and handleNetworkRestored() during that window.
    private var isRestoringSession = false
    /// Stored handle for the 150 ms deferred-pause task during session restore.
    /// Cancelled by resume() if the user taps play before the pause fires.
    private var restorePauseTask: Task<Void, Never>?
    /// True while the player is muted for the restore seek window (150 ms).
    /// Ensures volume is restored whether the pause fires or the user taps play first.
    private var isMutedForRestore = false
    /// Last saved volume from UserDefaults, defaulting to 0.7 when the key was never written.
    /// setVolume() never persists 0, so a missing key and an intentional-0 are indistinguishable
    /// here — using 0.7 as the initial default is correct.
    nonisolated var restoredVolume: Float {
        guard UserDefaults.standard.object(forKey: "minidisc.lastVolume") != nil else { return 0.7 }
        return Float(UserDefaults.standard.double(forKey: "minidisc.lastVolume"))
    }
    private var positionSaveTask: Task<Void, Never>?
    /// Task reserved for the playing-now notification. Cancelled on track change.
    private var playingNowTask: Task<Void, Never>?
    private var detector = ScrobbleThresholdDetector()
    /// Task scheduled to download and cache the current track at +30s of playback.
    /// Cancelled when track changes via cancelPendingCacheDownload().
    private var cacheDownloadTask: Task<Void, Never>?
    private let cacheSession: URLSession
    /// Task that prefetches the next queued track into cache ahead of the crossfade window.
    /// Cancelled on every track transition via cancelPendingPrefetch().
    private var prefetchTask: Task<Void, Never>?
    private var prefetchScheduled = false
    /// Invalidates any asynchronous resolve/prefetch work that belongs to an older playback intent.
    private var playbackGeneration: UInt64 = 0
    /// Orders overlapping scrubber/Control Center seeks; only the newest completion may update UI state.
    private var seekGeneration: UInt64 = 0
    /// Prevents a bad server/asset duration from spamming one diagnostic every progress tick.
    private var durationMismatchLoggedTrackID: String?
    private let prefetchSession: URLSession
    // Saved before a shuffle activation; nil when shuffle is off.
    private var originalQueueOrder: [DisplayableSong]?
    /// Single-slot guard preventing concurrent auto-extend fetches.
    private var autoExtendFetchTask: Task<Void, Never>?
    private nonisolated static let autoExtendUserDefaultsKey = "minidisc.player.autoExtendEnabled"

    /// Wall-clock time when the current track first started (used as event timestamp). Nil before first track.
    private var trackPlayStartDate: Date?
    /// Seconds of playhead movement accumulated for the current track.
    private var accumulatedPlayedSeconds: TimeInterval = 0
    /// Previous decoder-clock sample. Nil while paused/buffering and after a seek or track transition.
    private var lastCountedEngineProgress: TimeInterval?
    /// Set to true by handleEndOfTrack before a natural completion transition; reset after recording.
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
        self.cacheSession = URLSession(configuration: cacheConfig)

        let prefetchConfig = URLSessionConfiguration.default
        prefetchConfig.timeoutIntervalForRequest = 30
        prefetchConfig.timeoutIntervalForResource = 300
        prefetchConfig.networkServiceType = .background
        self.prefetchSession = URLSession(configuration: prefetchConfig)

        self.engine = engine
        let bridge = AudioEngineBridge()
        self.engineBridge = bridge
        // Wire delegate after all stored properties are initialised.
        bridge.service = self
        engine.delegate = bridge
    }

    /// Call from AppContainer after both PlayerService and NowPlayingService are created.
    func setNowPlayingService(_ service: any NowPlayingServiceProtocol) {
        nowPlayingService = service
    }


    // MARK: - Play

    func play(tracks: [DisplayableSong], startIndex: Int) async throws {
        guard tracks.indices.contains(startIndex) else { return }
        stoppedAtEndOfQueue = false
        playbackGeneration &+= 1
        let generation = playbackGeneration
        cancelPendingPrefetch()

        // Reset shuffle only when starting a genuinely new queue, not on internal skips
        // (skipToNext/skipToPrevious pass state.queue unchanged, so IDs match).
        let currentQueueIds = await MainActor.run { state.queue.map(\.id) }
        let isNewQueue = tracks.map(\.id) != currentQueueIds
        if isNewQueue {
            autoExtendFetchTask?.cancel()
            autoExtendFetchTask = nil
        }

        guard let serverId = await MainActor.run(body: { serverService.state.activeServer?.id }) else {
            await MainActor.run { state.playbackState = .error(.serverNotConfigured) }
            throw MinidiscError.serverNotConfigured
        }

        let previousPlaybackState = await MainActor.run { state.playbackState }
        await MainActor.run { state.playbackState = .loading }

        let song = tracks[startIndex]
        let source: MediaSource
        do {
            source = try await mediaResolver.resolve(songId: song.id, serverId: serverId)
        } catch let e as MinidiscError {
            guard generation == playbackGeneration else { return }
            await MainActor.run { state.playbackState = previousPlaybackState }
            throw e
        } catch {
            guard generation == playbackGeneration else { return }
            await MainActor.run { state.playbackState = previousPlaybackState }
            throw error
        }
        guard generation == playbackGeneration else {
            Logger.player.debug("[TRANSITION] discarded stale resolved source for '\(song.id, privacy: .public)'")
            return
        }

        if isNewQueue {
            originalQueueOrder = nil
        }
        await MainActor.run {
            if state.currentRadio != nil {
                Logger.player.debug("Ending live stream session — switching to queue playback")
            }
            state.queue = tracks
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
        await startPlayback(song: song, source: source, serverId: serverId)
    }

    private func startPlayback(song: DisplayableSong, source: MediaSource, serverId: UUID) async {
        // Record the previous track before transitioning (state.currentTrack still holds it here).
        await recordCurrentTrackPlayback(trigger: wasTrackCompletedNaturally ? "track_completed" : "user_skipped")
        wasTrackCompletedNaturally = false
        resetTrackAccumulator(isPlaying: true)

        // Cancel any pending +30s scrobble, cache download, and prefetch from the previous track.
        cancelPendingScrobble()
        cancelPendingCacheDownload()
        cancelPendingPrefetch()

        let config = await MainActor.run { replayGainSettings.config }
        let replayGainDB = ReplayGainService.gainDB(track: song, config: config)
        engine.applyReplayGain(dB: replayGainDB)
        logReplayGain(track: song, config: config, appliedDB: replayGainDB, context: "start")

        let songId = song.id
        durationMismatchLoggedTrackID = nil
        Task { [libraryService] in
            await libraryService.scrobble(songId: songId, submission: false)
        }
        playingNowTask = Task { [listenBrainzService, weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else { return }
            let stillActive = await MainActor.run { self.state.playbackState == .playing && self.state.currentTrack?.id == song.id }
            guard stillActive else { return }
            await listenBrainzService.notifyTrackStarted(song: song)
        }
        // Schedule cache download for stream sources only. Same +30s threshold as scrobble.
        // Phase 3: reads cacheSettings for format and cellular policy.
        if case .stream(let streamURL, let customHeaders) = source {
            // Capture settings at task-creation time — in-flight tasks use values from when they were scheduled.
            let (allowCellular, cacheFormat) = await MainActor.run {
                (cacheSettings.cacheOverCellular, cacheSettings.cacheFormat)
            }

            let cacheStreamURL: URL?
            if cacheFormat == .matchStream {
                cacheStreamURL = streamURL
            } else {
                cacheStreamURL = (try? await serverService.makeSwiftSonicClient())?.streamURL(
                    id: songId,
                    maxBitRate: cacheFormat.subsonicMaxBitRate,
                    format: cacheFormat.subsonicFormat
                )
            }

            if let cacheStreamURL {
                cacheDownloadTask = Task { [audioStreamCache, downloadService, serverService, cacheSession, weak self] in
                    try? await Task.sleep(for: .seconds(30))
                    guard !Task.isCancelled else { return }
                    if await audioStreamCache.cachedURL(forSongId: songId, serverId: serverId) != nil { return }
                    if await downloadService.isDownloaded(songId: songId, serverId: serverId) { return }
                    let isExpensive = await MainActor.run { serverService.state.isExpensive }
                    if isExpensive && !allowCellular {
                        Logger.player.debug("Cache skipped — cellular for '\(songId, privacy: .public)'")
                        return
                    }
                    do {
                        try await self?.downloadAndCache(
                            songId: songId,
                            serverId: serverId,
                            streamURL: cacheStreamURL,
                            customHeaders: customHeaders,
                            using: cacheSession
                        )
                    } catch {
                        Logger.player.debug("Cache download failed for '\(songId, privacy: .public)': \(error, privacy: .public)")
                    }
                }
            } else {
                Logger.player.debug("Cache: no URL for '\(songId, privacy: .public)' in \(cacheFormat.rawValue) — skipping")
            }
        }

        Logger.player.info("[TRANSITION] advancing to '\(song.title, privacy: .public)' (id=\(song.id, privacy: .public)) — starting playback")

        stopProgressTimer()
        stopPositionSaveTimer()
        liveStreamStallTask?.cancel()
        liveStreamStallTask = nil
        currentSource = source
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

        engine.play(trackID: song.id, url: source.url, headers: source.customHeaders)

        let duration = song.duration
        await MainActor.run {
            state.currentTrack = song
            state.duration = duration
            state.position = 0
            state.playbackState = .playing
            state.isPlaybackAvailable = true
        }
        // Give the engine the authoritative length — its own estimate drifts on transcoded streams,
        // which would arm the crossfade window at the wrong moment.
        engine.setTrackDuration(Double(duration))

        startProgressTimer()

        let artworkURL = await resolveArtworkURL(for: song)
        Logger.player.debug("[TRANSITION] attempting credentials fetch for NowPlaying headers")
        let artworkHeaders: [String: String]
        do {
            artworkHeaders = try await serverService.activeCredentials().customHeaders
        } catch {
            Logger.player.warning("[CREDENTIALS] activeCredentials failed, using empty headers: \(error, privacy: .public)")
            artworkHeaders = [:]
        }
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
        await saveSession()
        startPositionSaveTimer()
        preloadNextTrackArtwork()
        await evaluateAutoExtend()
    }

    // MARK: - Live Stream

    func playRadio(_ station: InternetRadioStation) async throws {
        playbackGeneration &+= 1
        let generation = playbackGeneration
        cancelPendingPrefetch()
        let source = try await mediaResolver.resolveRadio(station)

        let codecResult = await checkCodecSupport(url: source.url, headers: source.customHeaders)
        guard generation == playbackGeneration else { return }
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

        await recordCurrentTrackPlayback(trigger: "radio_started")
        resetTrackAccumulator(isPlaying: false)
        cancelPendingScrobble()
        cancelPendingCacheDownload()
        cancelPendingPrefetch()
        autoExtendFetchTask?.cancel()
        autoExtendFetchTask = nil
        engine.cancelPreload()
        engine.applyReplayGain(dB: 0)
        stopProgressTimer()
        stopPositionSaveTimer()
        liveStreamStallTask?.cancel()
        liveStreamStallTask = nil
        currentSource = source
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

        await MainActor.run {
            state.currentTrack = nil
            state.currentRadio = station
            state.isSmartShuffleActive = false
            state.originalQueueEndIndex = nil
            state.playbackState = .loading
            state.position = 0
            state.duration = 0
        }

        engine.play(trackID: "radio:\(station.id)", url: source.url, headers: source.customHeaders)

        await MainActor.run {
            state.playbackState = .playing
            state.isPlaybackAvailable = true
        }

        startProgressTimer()
        startLiveStreamStallMonitor(stationName: station.name)

        let artworkHeaders: [String: String]
        do {
            artworkHeaders = try await serverService.activeCredentials().customHeaders
        } catch {
            Logger.player.warning("[CREDENTIALS] activeCredentials failed, using empty headers: \(error, privacy: .public)")
            artworkHeaders = [:]
        }
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
        let tracks = try await libraryService.smartShuffleQueue(targetSize: 50)
        guard !tracks.isEmpty else {
            Logger.player.info("Smart shuffle returned empty — library too small or no downloads offline")
            throw MinidiscError.smartShuffleEmpty
        }

        // play(tracks:) resets isSmartShuffleActive via the new-queue check, so set the flag after.
        try await play(tracks: tracks, startIndex: 0)
        await MainActor.run { state.isSmartShuffleActive = true }

        Logger.player.info("Started Smart Shuffle session with \(tracks.count) tracks")
    }

    // MARK: - Instant Mix

    /// Starts an Instant Mix. When the caller can supply the seed TRACK (song seeds — every menu that
    /// offers "Instant Mix" on a song already holds it), that track starts immediately and the mix is
    /// built behind it. Album and artist seeds have no track in hand and keep the blocking path.
    ///
    /// This removes the wait rather than shortening it. Measured against a real AudioMuse server, the
    /// blocking path costs 36 s of silence — 12.8 s for the seed query, then 23 s for the fan-out —
    /// and the fan-out calls slow each other down by ~70% while they run.
    func playInstantMix(from seed: InstantMixSeed, startingWith seedTrack: DisplayableSong?) async throws {
        // `??` cannot host an async right-hand side (autoclosures are not concurrency-aware).
        let resolved: DisplayableSong?
        if let seedTrack {
            resolved = seedTrack
        } else {
            resolved = await starterTrack(for: seed)
        }
        guard let starter = resolved else {
            try await buildThenPlayInstantMix(from: seed)
            return
        }
        try await play(tracks: [starter], startIndex: 0)
        Logger.player.info("[MIX-TIMING] seed '\(starter.id, privacy: .public)' playing immediately — mix building behind it")
        // Auto-extend deliberately stays OFF until the mix lands. Turning it on now re-evaluates at
        // once, and with a one-track queue it would fill the gap with generic similar tracks — racing,
        // and partly duplicating, the mix we are about to append.
        // The seed is already playing, so the audio background mode covers this on its own — the
        // assertion is the safety net for the user who hits pause while the mix is still building.
        Task { await BackgroundActivity.run("instant-mix") { await self.appendInstantMix(from: seed, behind: starter) } }
    }

    /// A track to start on when the caller had none. Album and artist mixes are offered from menus and
    /// headers that hold no song, so resolving one here — rather than at each call site — is what makes
    /// the instant start universal instead of song-only.
    ///
    /// Costs one or two catalogue calls, ~100 ms each measured, against a mix build of 30 s and more.
    /// Returning nil falls back to the blocking path, so a failure here is never worse than before.
    private func starterTrack(for seed: InstantMixSeed) async -> DisplayableSong? {
        switch seed {
        case .song:
            // Every song entry point already passes the track it was invoked on, and LibraryService
            // has no single-song fetch to fall back on.
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

    /// Builds the mix off the critical path and grafts it behind the already-playing seed.
    private func appendInstantMix(from seed: InstantMixSeed, behind seedTrack: DisplayableSong) async {
        do {
            let tracks = try await libraryService.instantMix(from: seed, count: 100)
            // The build takes tens of seconds. If the user moved on in the meantime, appending would
            // graft the mix onto an unrelated queue.
            guard await MainActor.run(body: { state.currentTrack?.id == seedTrack.id }) else {
                Logger.player.info("[INSTANT-MIX] built mix discarded — playback moved on during the build")
                return
            }
            let fresh = tracks.filter { $0.id != seedTrack.id }
            guard !fresh.isEmpty else {
                // A server with no similarity data (no AudioMuse, no Navidrome agent) answers empty.
                // Endless play still works there — it is built on listening history, discographies and
                // genres, not on the similarity endpoints — so fall through to it rather than leaving
                // the seed to play alone and stop.
                Logger.player.info("[INSTANT-MIX] no similarity data for seed — continuing with the library-based endless queue")
                await setAutoExtendEnabled(true)
                await MainActor.run {
                    toastService.show("No Instant Mix data for this track — continuing from your library.", style: .info, duration: 4.0)
                }
                return
            }
            await appendToQueue(fresh)
            await setAutoExtendEnabled(true)
            Logger.player.info("[INSTANT-MIX] appended \(fresh.count, privacy: .public) tracks behind the seed (auto-extend on)")
        } catch {
            Logger.player.error("[INSTANT-MIX] background build failed: \(error, privacy: .public)")
            await MainActor.run { toastService.showError("Couldn't build the Instant Mix.") }
        }
    }

    /// The original blocking path: nothing plays until the whole mix is built. Still used for album and
    /// artist seeds, where there is no track to start from.
    private func buildThenPlayInstantMix(from seed: InstantMixSeed) async throws {
        // End-to-end latency, which is what the user waits through: the whole mix is built before a
        // single note plays. Split into build vs start so the two are attributable separately.
        let tStart = Date()
        let tracks = try await libraryService.instantMix(from: seed, count: 100)
        let buildMs = Int(Date().timeIntervalSince(tStart) * 1000)
        guard !tracks.isEmpty else {
            Logger.player.info("Instant Mix returned empty — no similarity data for seed")
            throw MinidiscError.instantMixEmpty
        }
        let tPlay = Date()
        try await play(tracks: tracks, startIndex: 0)
        Logger.player.info("[MIX-TIMING] end-to-end=\(Int(Date().timeIntervalSince(tStart) * 1000), privacy: .public)ms (build=\(buildMs, privacy: .public)ms, start=\(Int(Date().timeIntervalSince(tPlay) * 1000), privacy: .public)ms)")
        // An Instant Mix is meant to be endless — turn on auto-extend so the queue keeps growing with
        // similar tracks (same mechanism as the automix) instead of running in circles on a short seed set.
        await setAutoExtendEnabled(true)
        Logger.player.info("Started Instant Mix with \(tracks.count) tracks (auto-extend on)")
    }

    func setVolume(_ volume: Float) async {
        let clamped = max(0, min(1, volume))
        engine.volume = clamped
        // Don't persist 0 — muting should not overwrite the saved restore volume.
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
        let selectedGain = config.mode == .track
            ? track.replayGainTrackGain
            : track.replayGainAlbumGain
        let selectedPeak = config.mode == .track
            ? track.replayGainTrackPeak
            : track.replayGainAlbumPeak
        let gainDescription = selectedGain.map { String(format: "%.2f", $0) } ?? "missing"
        let peakDescription = selectedPeak.map { String(format: "%.4f", $0) } ?? "missing"
        let fallbackDescription = track.replayGainFallbackGain.map { String(format: "%.2f", $0) } ?? "missing"
        Logger.player.info(
            "[REPLAYGAIN] context=\(context, privacy: .public) track='\(track.id, privacy: .public)' enabled=\(config.enabled, privacy: .public) mode=\(config.mode.rawValue, privacy: .public) selectedGain=\(gainDescription, privacy: .public)dB selectedPeak=\(peakDescription, privacy: .public) fallback=\(fallbackDescription, privacy: .public)dB preAmp=\(config.preAmp, format: .fixed(precision: 1))dB applied=\(appliedDB, format: .fixed(precision: 2))dB"
        )
    }

    func crossfadeSettingsDidChange() async {
        crossfadeConfig = await MainActor.run { crossfadeSettings.config }
        Logger.player.info(
            "[CROSSFADE] settings duration=\(self.crossfadeConfig.duration, format: .fixed(precision: 1))s keepAlbumTracksBackToBack=\(self.crossfadeConfig.disableForGapless, privacy: .public)"
        )
        playbackGeneration &+= 1
        cancelPendingPrefetch()
        engine.cancelPreload()
    }

    func setAutoExtendEnabled(_ enabled: Bool) async {
        if enabled {
            // Endless play owns the queue order, so loop and shuffle are turned off rather than left
            // to conflict with it. Repeat especially: evaluateAutoExtend refuses to run while a loop
            // mode is active, which used to leave the infinity toggle lit and doing nothing. Clearing
            // them here makes the exclusivity visible in the UI instead of silent.
            // Done BEFORE the flag is set so setRepeatMode's own re-evaluation still sees it disabled
            // and cannot fire a fetch early.
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
            // State is updated before re-evaluation so the guards inside read fresh values.
            await evaluateAutoExtend()
        } else {
            autoExtendFetchTask?.cancel()
            autoExtendFetchTask = nil
            await truncateExtensions()
        }
        Logger.player.info("Auto-extend \(enabled ? "enabled" : "disabled", privacy: .public)")
    }

    // MARK: - Auto-extend

    /// Reads queue position and fires a background fetch + append when ≤15 tracks remain.
    /// Called at the end of every startPlayback(). Guarded by a single-slot task to prevent
    /// parallel fetches when tracks advance rapidly. Errors are swallowed — natural queue
    /// end is the graceful fallback.
    private func evaluateAutoExtend() async {
        let (isEnabled, repeatMode, currentRadio, remaining, queueIds, seedTrackId) = await MainActor.run {
            let remaining = state.queue.count - state.currentIndex - 1
            return (state.isAutoExtendEnabled, state.repeatMode, state.currentRadio, remaining, Set(state.queue.map(\.id)), state.currentTrack?.id)
        }
        guard isEnabled else { return }
        guard repeatMode == .off else { return }
        guard currentRadio == nil else { return }
        guard autoExtendFetchTask == nil else { return }
        // Trigger threshold : 15 or fewer tracks remaining (including zero — covers singles
        // and starting from the last track of an album).
        guard remaining <= 15 else { return }

        Logger.player.info("Auto-extend triggered: \(remaining) tracks remaining, fetching 50 seeded on '\(seedTrackId ?? "none", privacy: .public)'")

        let generation = playbackGeneration
        autoExtendFetchTask = Task { [libraryService, weak self] in
            defer { Task { await self?.clearAutoExtendFetchTask() } }
            do {
                // Seeded on the track playing now — a sonic Instant Mix — with the library heuristic
                // as top-up and fallback (the upstream "endless" behaviour).
                let tracks = try await libraryService.endlessExtension(seedTrackId: seedTrackId, targetSize: 50, excludedIds: queueIds)
                guard !tracks.isEmpty else {
                    Logger.player.debug("Auto-extend fetch returned empty — library exhausted or offline without downloads")
                    return
                }
                guard !Task.isCancelled,
                      await self?.isAutoExtendContextValid(generation: generation) == true else {
                    Logger.player.debug("Discarded stale auto-extend result")
                    return
                }
                await self?.anchorOriginalQueueBoundaryIfNeeded()
                await self?.appendAutoExtendedTracks(tracks)
                Logger.player.info("Auto-extend appended \(tracks.count) tracks to queue")
            } catch {
                Logger.player.debug("Auto-extend fetch failed: \(error, privacy: .public)")
            }
        }
    }

    private func clearAutoExtendFetchTask() {
        autoExtendFetchTask = nil
    }

    private func isAutoExtendContextValid(generation: UInt64) async -> Bool {
        guard generation == playbackGeneration else { return false }
        return await MainActor.run {
            state.isAutoExtendEnabled && state.repeatMode == .off && !state.isLiveStream
        }
    }

    private func appendAutoExtendedTracks(_ tracks: [DisplayableSong]) async {
        guard !tracks.isEmpty else { return }
        await MainActor.run { state.queue.append(contentsOf: tracks) }
        await saveSession()
    }

    /// Records the current queue count as the boundary between user-intentional and
    /// auto-extended tracks. No-op if the boundary is already set (first extend wins).
    private func anchorOriginalQueueBoundaryIfNeeded() async {
        let alreadySet = await MainActor.run { state.originalQueueEndIndex != nil }
        guard !alreadySet else { return }
        let queueCount = await MainActor.run { state.queue.count }
        await MainActor.run { state.originalQueueEndIndex = queueCount }
        Logger.player.debug("Auto-extend boundary anchored at \(queueCount)")
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
        finalizePlaySegment()
        engine.pause()
        // Flip the UI state BEFORE deactivating the audio session — setActive(false) routinely takes
        // hundreds of ms and used to hold the play/pause icon hostage behind it.
        await MainActor.run { state.playbackState = .paused }
        sessionActivationRetryTask?.cancel()
        sessionActivationRetryTask = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        await pushPositionSnapshot(rate: 0.0)
        stopProgressTimer()
        stopPositionSaveTimer()
        await saveSession()
    }

    func resume() async {
        // User explicitly pressed play — cancel any pending restore auto-pause and lift eof guard.
        restorePauseTask?.cancel()
        restorePauseTask = nil
        if isMutedForRestore {
            engine.volume = restoredVolume
            isMutedForRestore = false
        }
        isRestoringSession = false
        // Flip the UI state first — session activation (and the cold-restore re-resolve below) can
        // take hundreds of ms, and the play/pause icon must not wait on them.
        await MainActor.run { state.playbackState = .playing }
        configureAudioSessionIfNeeded()
        // Lazily start the accumulator for session-restored tracks that resume for the first time.
        if trackPlayStartDate == nil { trackPlayStartDate = Date() }
        lastCountedEngineProgress = engine.progress

        // Resuming after the queue ended (stopped cleanly at the end, repeat off): restart from track 0, NOT
        // the last track — replaying it would hit EOF immediately and re-stop (the mini-loop). A normal mid-track
        // pause leaves this flag false and falls through to the regular resume below.
        if stoppedAtEndOfQueue {
            stoppedAtEndOfQueue = false
            pendingRestoreInfo = nil
            let queue = await MainActor.run { state.queue }
            if !queue.isEmpty {
                try? await play(tracks: queue, startIndex: 0)
                return
            }
        }

        // Cold-restore path: session activation was deferred at launch, so the player was never
        // started. Start fresh now that the user has explicitly triggered playback.
        if engine.isReady, let source = currentSource {
            if let info = pendingRestoreInfo, info.pause {
                pendingRestoreInfo = (seekTime: info.seekTime, pause: false)
            }
            if let info = pendingRestoreInfo, info.seekTime > 1 {
                engine.volume = 0
                isMutedForRestore = true
            }
            // Re-resolve through MediaResolver — the stored source was resolved at
            // launch and may be hours old; a stale stream URL fails silently. This
            // mirrors the always-re-resolve invariant every other playback start holds.
            let freshSource = await refreshedColdStartSource() ?? source
            currentSource = freshSource
            let trackID = await MainActor.run { state.currentTrack?.id ?? "restored" }
            engine.play(trackID: trackID, url: freshSource.url, headers: freshSource.customHeaders)
            let restoredDuration = await MainActor.run { state.duration }
            engine.setTrackDuration(restoredDuration)
        } else {
            engine.resume()
        }
        await pushPositionSnapshot(rate: 1.0)
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
        playbackGeneration &+= 1
        await recordCurrentTrackPlayback(trigger: "stopped")
        cancelPendingScrobble()
        cancelPendingCacheDownload()
        cancelPendingPrefetch()
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
        sessionActivationRetryTask?.cancel()
        sessionActivationRetryTask = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        accumulatedPlayedSeconds = 0
        lastCountedEngineProgress = nil
        trackPlayStartDate = nil
        engine.applyReplayGain(dB: 0)
        currentSource = nil
        pendingRestoreInfo = nil
        isRestoringSession = false
        await nowPlayingService?.stop()
        await sessionService.clear()
        await MainActor.run {
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
        finalizePlaySegment()
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
        lastCountedEngineProgress = confirmedPosition
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
        let (queue, currentIndex, repeatMode) = await MainActor.run {
            (state.queue, state.currentIndex, state.repeatMode)
        }
        let nextIndex = currentIndex + 1
        Logger.player.info("[TRANSITION] skipToNext: currentIndex=\(currentIndex) nextIndex=\(nextIndex) queueCount=\(queue.count)")

        if nextIndex < queue.count {
            let next = queue[nextIndex]
            Logger.player.info("[TRANSITION] skipToNext → track id=\(next.id, privacy: .public) title=\(next.title, privacy: .public)")
            try await play(tracks: queue, startIndex: nextIndex)
        } else if repeatMode == .all {
            Logger.player.info("[TRANSITION] skipToNext → wrap-around (repeatAll), restarting queue from index 0")
            try await play(tracks: queue, startIndex: 0)
        } else {
            await pauseAtEndOfQueue()
        }
    }

    func skipToPrevious() async throws {
        guard await MainActor.run(body: { !state.isLiveStream }) else {
            Logger.player.debug("skipToPrevious ignored — live stream mode")
            return
        }
        let (queue, currentIndex, position) = await MainActor.run {
            (state.queue, state.currentIndex, state.position)
        }

        // < 3 s into the track: go back; at track 0 or after 3 s: restart current.
        if position >= 3 || currentIndex == 0 {
            await seek(to: 0)
        } else {
            try await play(tracks: queue, startIndex: currentIndex - 1)
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
        guard let data = await sessionService.loadRestoredSession() else { return }

        let track = data.queue[data.currentIndex]
        let restoredDuration = max(data.currentTrackDuration, track.duration)
        let nonnegativePosition = max(data.currentPosition, 0)
        let restoredPosition = restoredDuration > 0
            ? min(nonnegativePosition, restoredDuration)
            : nonnegativePosition
        await MainActor.run {
            state.queue = data.queue
            state.currentIndex = data.currentIndex
            state.currentTrack = track
            state.currentRadio = nil
            state.position = restoredPosition
            state.duration = restoredDuration
            state.repeatMode = data.repeatMode
            state.playbackState = .paused
        }

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

        await prepareCurrentTrackForRestoration(track: track, position: restoredPosition)
        Logger.player.info("Session restored: \(data.queue.count) tracks, index \(data.currentIndex), pos=\(restoredPosition, format: .fixed(precision: 1))s")
    }

    private func prepareCurrentTrackForRestoration(track: DisplayableSong, position: TimeInterval) async {
        // Set the guard immediately — before any await — so handleNetworkRestored() cannot
        // race in during mediaResolver.resolve() and trigger a second play() call that would
        // consume pendingRestoreInfo before the deferred seek is applied.
        isRestoringSession = true

        guard let serverId = await MainActor.run(body: { serverService.state.activeServer?.id }) else {
            Logger.player.warning("Session restore: no active server, skipping player prep")
            isRestoringSession = false
            return
        }

        let source: MediaSource
        do {
            source = try await mediaResolver.resolve(songId: track.id, serverId: serverId)
        } catch {
            Logger.player.error("Session restore: failed to resolve media — \(error)")
            await MainActor.run { state.isPlaybackAvailable = false }
            isRestoringSession = false
            return
        }

        stopProgressTimer()
        currentSource = source
        // Seek to saved position on first play; pause flag cleared in resume() when user
        // explicitly starts playback, or kept if user hasn't tapped play yet.
        pendingRestoreInfo = (seekTime: position, pause: true)

        // Apply ReplayGain after restore state is fully committed (no suspension between
        // currentSource and pendingRestoreInfo above). globalGain is set on the EQ node
        // and takes effect when audio flows, so applying while paused is correct.
        let config = await MainActor.run { replayGainSettings.config }
        engine.applyReplayGain(dB: ReplayGainService.gainDB(track: track, config: config))
        Logger.player.debug("[RESTORE] ReplayGain applied for '\(track.title, privacy: .public)'")

        // Session activation is intentionally deferred to the first user-triggered play.
        // Activating here would grab the audio route from other devices (e.g. Mac+AirPods)
        // before the user has indicated intent to listen.

        await MainActor.run { state.isPlaybackAvailable = true }
        Logger.player.info("Session restore: '\(track.title)' queued at \(position, format: .fixed(precision: 1))s (playback deferred)")

        // Populate MPNowPlayingInfoCenter in paused state so lock screen controls appear
        // immediately when the user resumes — resume() only sends a position-only update
        // which would start from an empty dict otherwise.
        let duration = await MainActor.run { state.duration }
        let artworkURL = await resolveArtworkURL(for: track)
        let artworkHeaders: [String: String]
        do {
            artworkHeaders = try await serverService.activeCredentials().customHeaders
        } catch {
            Logger.player.warning("[CREDENTIALS] activeCredentials failed, using empty headers: \(error, privacy: .public)")
            artworkHeaders = [:]
        }
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
        isRestoringSession = false
    }

    func handleNetworkRestored() async {
        // Don't race with an in-progress session restore; prepareCurrentTrackForRestoration
        // sets isRestoringSession before its first await so this check is reliable.
        guard !isRestoringSession else {
            Logger.player.info("Network restored — session restore already in progress, skipping re-prepare")
            return
        }
        let (isAvailable, track, position) = await MainActor.run {
            (state.isPlaybackAvailable, state.currentTrack, state.position)
        }
        guard !isAvailable, let track else { return }
        Logger.player.info("Network restored — re-preparing '\(track.title)'")
        await prepareCurrentTrackForRestoration(track: track, position: position)
    }

    // MARK: - Position save timer

    private func startPositionSaveTimer() {
        stopPositionSaveTimer()
        positionSaveTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                guard !isRestoringSession else { continue }
                // Position-only update — queue/track/mode already saved at each state change. Check the
                // actor-local seekability first (no MainActor hop): a non-seekable stream can't restore a
                // position, so skip the hop entirely rather than reading state only to discard it.
                guard engine.isSeekable else { continue }
                let (isPlaying, pos) = await MainActor.run {
                    (state.playbackState == .playing, state.position)
                }
                guard isPlaying else { continue }
                await sessionService.savePosition(pos)
            }
        }
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
                let progress = self.engine.progress
                let audioDuration = self.engine.duration
                let durationSnapshot = await MainActor.run {
                    // Refine the duration BEFORE clamping the position against it. The engine's own
                    // value lands as soon as the stream reports its length; clamping first pinned the
                    // position for a tick against a metadata length already known to be wrong.
                    let shouldRefineEngineDuration = audioDuration > self.state.duration + 0.5
                    if shouldRefineEngineDuration {
                        self.state.duration = audioDuration
                    }
                    // Never turn the playhead into a fake duration. If an estimate is too short,
                    // growing duration to `progress` leaves the player permanently at -0:00 and makes
                    // a seek-to-end target the current position. Keep both facts independently visible.
                    self.state.position = max(progress, 0)
                    return (
                        trackID: self.state.currentTrack?.id,
                        duration: self.state.duration,
                        shouldRefineEngineDuration: shouldRefineEngineDuration
                    )
                }
                if durationSnapshot.shouldRefineEngineDuration {
                    self.engine.setTrackDuration(audioDuration)
                }
                if let trackID = durationSnapshot.trackID,
                   progress > durationSnapshot.duration + 0.5 {
                    await self.logDurationMismatchIfNeeded(
                        trackID: trackID,
                        progress: progress,
                        stateDuration: durationSnapshot.duration,
                        engineDuration: audioDuration
                    )
                }
                await self.accumulatePlaybackProgress(progress)
                await self.periodicNowPlayingPush(elapsed: progress)
                await self.checkScrobbleThreshold()
                await self.checkPrefetchThreshold()
            }
        }
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
        playingNowTask?.cancel()
        playingNowTask = nil
    }

    private func checkScrobbleThreshold() async {
        guard let song = await MainActor.run(body: { state.currentTrack }) else { return }
        fireScrobbleIfThresholdMet(song: song)
    }

    // Synchronous split required by Swift 6: mutating a struct property (`detector`)
    // is only legal in a non-async actor method (no suspension points → no reentrancy window).
    private func fireScrobbleIfThresholdMet(song: DisplayableSong) {
        let duration = song.duration
        let songId = song.id
        guard detector.check(duration: duration, accumulated: accumulatedPlayedSeconds) else { return }
        let startDate = trackPlayStartDate ?? Date()
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
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchScheduled = false
    }

    nonisolated static func shouldSchedulePrefetch(crossfadeDuration: Double, remaining: Double) -> Bool {
        remaining <= max(0, crossfadeDuration) + 15.0
    }

    nonisolated static func shouldProceedWithPrefetch(isExpensive: Bool, allowCellular: Bool) -> Bool {
        if isExpensive && !allowCellular { return false }
        return true
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
        let (currentIndex, duration, position) = await MainActor.run {
            (state.currentIndex, state.duration, state.position)
        }
        guard duration > 0 else { return }
        let remaining = duration - position
        guard PlayerService.shouldSchedulePrefetch(crossfadeDuration: crossfadeConfig.duration, remaining: remaining) else { return }

        let nextIndex = currentIndex + 1
        let resolved: (nextSong: DisplayableSong, serverId: UUID)? = await MainActor.run {
            guard state.queue.indices.contains(nextIndex),
                  let serverId = serverService.state.activeServer?.id else { return nil }
            return (state.queue[nextIndex], serverId)
        }
        guard let resolved else { return }

        prefetchScheduled = true
        Logger.player.debug("[PREFETCH] scheduling prefetch for '\(resolved.nextSong.title, privacy: .public)' (remaining=\(String(format: "%.1f", remaining))s)")
        let generation = playbackGeneration
        await prefetchNextTrack(
            nextSong: resolved.nextSong,
            serverId: resolved.serverId,
            generation: generation
        )
    }

    private func prefetchNextTrack(
        nextSong: DisplayableSong,
        serverId: UUID,
        generation: UInt64
    ) async {
        let songId = nextSong.id
        guard await isPrefetchContextValid(songId: songId, serverId: serverId, generation: generation) else { return }

        if await audioStreamCache.cachedURL(forSongId: songId, serverId: serverId) != nil {
            Logger.player.debug("[PREFETCH] '\(songId, privacy: .public)' already cached — skip")
            await preloadNextForGapless(nextSong: nextSong, serverId: serverId, generation: generation)
            return
        }
        if await downloadService.isDownloaded(songId: songId, serverId: serverId) {
            Logger.player.debug("[PREFETCH] '\(songId, privacy: .public)' already downloaded — skip")
            await preloadNextForGapless(nextSong: nextSong, serverId: serverId, generation: generation)
            return
        }

        let (isExpensive, allowCellular, cacheFormat) = await MainActor.run {
            (serverService.state.isExpensive, cacheSettings.cacheOverCellular, cacheSettings.cacheFormat)
        }
        guard PlayerService.shouldProceedWithPrefetch(isExpensive: isExpensive, allowCellular: allowCellular) else {
            Logger.player.debug("[PREFETCH] '\(songId, privacy: .public)' skipped — cellular guard")
            // No cache write will happen, so the track will stream at advance — preload that stream.
            await preloadNextForGapless(nextSong: nextSong, serverId: serverId, generation: generation)
            return
        }

        let streamURL: URL
        let customHeaders: [String: String]
        if cacheFormat == .matchStream {
            guard let source = try? await mediaResolver.resolve(songId: songId, serverId: serverId),
                  case .stream(let resolvedURL, let resolvedHeaders) = source else {
                Logger.player.debug("[PREFETCH] '\(songId, privacy: .public)' no stream source — skip")
                return
            }
            streamURL = resolvedURL
            customHeaders = resolvedHeaders
        } else {
            guard let resolvedURL = (try? await serverService.makeSwiftSonicClient())?.streamURL(
                id: songId,
                maxBitRate: cacheFormat.subsonicMaxBitRate,
                format: cacheFormat.subsonicFormat,
                estimateContentLength: true
            ) else {
                Logger.player.debug("[PREFETCH] '\(songId, privacy: .public)' no cache-format URL — skip")
                return
            }
            streamURL = resolvedURL
            do {
                customHeaders = try await serverService.activeCredentials().customHeaders
            } catch {
                Logger.player.debug("[PREFETCH] '\(songId, privacy: .public)' credentials unavailable — skip")
                return
            }
        }

        prefetchTask = Task { [prefetchSession, weak self] in
            guard !Task.isCancelled else { return }
            do {
                try await self?.downloadAndCache(
                    songId: songId,
                    serverId: serverId,
                    streamURL: streamURL,
                    customHeaders: customHeaders,
                    using: prefetchSession
                )
                Logger.player.info("[PREFETCH] '\(songId, privacy: .public)' prefetch complete")
            } catch {
                Logger.player.debug("[PREFETCH] '\(songId, privacy: .public)' prefetch failed: \(error, privacy: .public)")
            }
        }
        // Warm the standby deck immediately while the complete cache download runs in parallel.
        // Waiting for a large FLAC to finish downloading can consume the entire 15 s lead window,
        // leaving no ready deck when the configured crossfade should begin.
        await preloadNextForGapless(
            nextSong: nextSong,
            serverId: serverId,
            generation: generation
        )
    }

    /// Pre-buffers the next track in the engine for a seamless hand-off. The crossfade itself is
    /// delegated here (duration > 0 = engine-blended overlap; gapless pairs stay at 0 when the user
    /// asked crossfade to stand aside for them). Repeat-one always skips: the queue's next is not
    /// what actually plays next.
    private func preloadNextForGapless(
        nextSong: DisplayableSong,
        serverId: UUID,
        generation: UInt64
    ) async {
        let songId = nextSong.id
        guard await isPrefetchContextValid(songId: songId, serverId: serverId, generation: generation) else { return }
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
        guard await isPrefetchContextValid(songId: songId, serverId: serverId, generation: generation) else {
            Logger.player.debug("[PREFETCH] discarded stale preload for '\(songId, privacy: .public)'")
            return
        }
        let replayGainConfig = await MainActor.run { replayGainSettings.config }
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
        generation: UInt64
    ) async -> Bool {
        guard generation == playbackGeneration, !Task.isCancelled else { return false }
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

    // MARK: - Play-time accumulator

    /// Breaks playhead-delta continuity. The next playing tick establishes a new baseline.
    private func finalizePlaySegment() {
        lastCountedEngineProgress = nil
    }

    /// Resets all per-track accumulator state for the next track.
    /// Call immediately after recordCurrentTrackPlayback() in every transition site.
    private func resetTrackAccumulator(isPlaying: Bool) {
        accumulatedPlayedSeconds = 0
        trackPlayStartDate = Date()
        // startPlayback calls this before the new item is installed, so using the engine's current
        // position here would accidentally seed the new track with the outgoing track's clock.
        lastCountedEngineProgress = nil
        detector.reset()
    }

    private func accumulatePlaybackProgress(_ progress: TimeInterval) async {
        guard progress.isFinite, progress >= 0 else { return }
        let shouldCount = await MainActor.run {
            state.playbackState == .playing && !state.isLiveStream
        }
        guard shouldCount else {
            lastCountedEngineProgress = nil
            return
        }
        guard let previous = lastCountedEngineProgress else {
            lastCountedEngineProgress = progress
            return
        }
        let delta = progress - previous
        // A normal 500 ms tick is ~0.5 s. Ignore discontinuities caused by seek, deck promotion,
        // source restart or a long suspended task instead of counting unheard time.
        if delta >= 0, delta <= 2.0 {
            accumulatedPlayedSeconds += delta
        }
        lastCountedEngineProgress = progress
    }

    // MARK: - Stats recording

    private func recordCurrentTrackPlayback(trigger: String = "unknown") async {
        guard let song = await MainActor.run(body: { state.currentTrack }),
              let startDate = trackPlayStartDate else { return }
        guard let serverId = await MainActor.run(body: { serverService.state.activeServer?.id }) else { return }
        await accumulatePlaybackProgress(engine.progress)
        let durationListened = accumulatedPlayedSeconds
        guard durationListened >= 30 else {
            Logger.player.debug("[STATS] Skip — durationListened=\(durationListened, format: .fixed(precision: 1))s < 30s for '\(song.title, privacy: .public)'")
            return
        }

        let trackDuration = await MainActor.run { state.duration }
        let dto = PlaybackEventDTO(
            trackId: song.id,
            trackTitle: song.title,
            albumId: song.albumId,
            albumTitle: song.albumName,
            artistId: song.artistId,
            artistName: song.artist ?? "",
            genre: song.genre,
            timestamp: startDate,
            durationListened: durationListened,
            trackDuration: trackDuration,
            wasCompleted: wasTrackCompletedNaturally,
            serverId: serverId.uuidString
        )
        await statsService.recordPlayback(dto, trigger: trigger)
        let artistIdForLog = song.artistId ?? "nil"
        let durationForLog = String(format: "%.1f", durationListened)
        let trackDurationForLog = String(format: "%.1f", trackDuration)
        Logger.player.debug(
            "[STATS] Recorded: trigger=\(trigger, privacy: .public) trackId=\(song.id, privacy: .public) artistId=\(artistIdForLog, privacy: .public) durationListened=\(durationForLog, privacy: .public)s trackDuration=\(trackDurationForLog, privacy: .public)s startedAt=\(startDate, privacy: .public) completed=\(self.wasTrackCompletedNaturally, privacy: .public)"
        )
    }

    // MARK: - End of track

    func handleEndOfTrack() async {
        guard !isRestoringSession else {
            Logger.player.warning("[END-OF-TRACK] suppressed — session restore in progress")
            return
        }
        guard !isHandlingEndOfTrack else {
            Logger.player.warning("[END-OF-TRACK] already handling — skipping duplicate")
            return
        }
        isHandlingEndOfTrack = true
        defer { isHandlingEndOfTrack = false }
        let repeatMode = await MainActor.run { state.repeatMode }
        if repeatMode == .one {
            // Record this completed listen, then restart the same track.
            wasTrackCompletedNaturally = true
            await recordCurrentTrackPlayback(trigger: "repeat_one")
            wasTrackCompletedNaturally = false
            resetTrackAccumulator(isPlaying: true)
            if let source = currentSource {
                let trackID = await MainActor.run { state.currentTrack?.id ?? "repeat" }
                engine.play(trackID: trackID, url: source.url, headers: source.customHeaders)
            }
        } else {
            // Signal natural completion — recordCurrentTrackPlayback() reads this in startPlayback().
            wasTrackCompletedNaturally = true
            do {
                try await skipToNext()
            } catch {
                Logger.player.error("[TRANSITION] handleEndOfTrack: skipToNext() failed: \(error, privacy: .public)")
            }
        }
    }

    /// The last track of the queue ended naturally with repeat off. Stop cleanly AT THE END — no wrap, and no
    /// muted "parking" play of track 1 (that muted play, plus its mute→pause race, was the phantom: a leaked
    /// audio fragment / RCC churn). The queue + current index/track are kept and the position is parked at the
    /// end; `stoppedAtEndOfQueue` makes `resume()` restart the queue from track 0 (option a).
    private func pauseAtEndOfQueue() async {
        // Record the last track's completion (it ended naturally), then reset the accumulators.
        await recordCurrentTrackPlayback(trigger: "end_of_queue")
        wasTrackCompletedNaturally = false
        accumulatedPlayedSeconds = 0
        lastCountedEngineProgress = nil
        trackPlayStartDate = nil

        stopProgressTimer()
        stopPositionSaveTimer()
        // The engine is at EOF — stop it (NO parking play) and release the session.
        engine.stop()
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
    func handleEngineState(_ newState: AudioEngineState) async {
        switch newState {
        case .playing:
            guard let info = pendingRestoreInfo else {
                if lastCountedEngineProgress == nil { lastCountedEngineProgress = engine.progress }
                break
            }
            pendingRestoreInfo = nil
            // Seek while the engine is running. AVPlayer may still accept the request while its
            // seekable ranges are being populated, so isSeekable is diagnostic rather than a gate.
            if info.seekTime > 1 {
                let succeeded = await engine.seek(to: info.seekTime)
                Logger.player.info(
                    "[RESTORE] seek target=\(info.seekTime, format: .fixed(precision: 3))s completed=\(succeeded, privacy: .public) landed=\(self.engine.progress, format: .fixed(precision: 3))s"
                )
                lastCountedEngineProgress = engine.progress
            }
            guard info.pause else {
                if isMutedForRestore {
                    engine.volume = restoredVolume
                    isMutedForRestore = false
                }
                isRestoringSession = false
                break
            }
            // Give processSeekTime() 150 ms to clear the render buffer and reopen
            // the HTTP connection at the correct byte offset before pausing.
            // Stored so resume() can cancel the deferred pause via task.cancel().
            restorePauseTask = Task {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                self.restorePauseTask = nil
                self.engine.pause()
                self.engine.volume = self.restoredVolume
                self.isMutedForRestore = false
                await MainActor.run { self.state.playbackState = .paused }
                self.stopProgressTimer()
                self.isRestoringSession = false
                Logger.player.info("[RESTORE] seek landed — paused at \(self.engine.progress, format: .fixed(precision: 1))s")
            }
        case .buffering, .paused, .stopped:
            finalizePlaySegment()
        case .error:
            finalizePlaySegment()
            stopProgressTimer()
            stopPositionSaveTimer()
            cancelPendingCacheDownload()
            cancelPendingPrefetch()
            engine.stop()
            Logger.player.error("[PLAYER] engine entered error state")
            let isLive = await MainActor.run { state.isLiveStream }
            if isLive {
                let name = await MainActor.run { state.currentRadio?.name ?? "" }
                await handleLiveStreamFailure(stationName: name, error: nil)
            } else {
                await MainActor.run { state.playbackState = .error(.timeout) }
            }
        default:
            break
        }
    }

    /// Called by the engine bridge on unexpected errors.
    func handleEngineError(_ message: String) async {
        finalizePlaySegment()
        stopProgressTimer()
        stopPositionSaveTimer()
        cancelPendingCacheDownload()
        cancelPendingPrefetch()
        engine.stop()
        Logger.player.error("[PLAYER] engine unexpected error: \(message, privacy: .public)")
        let isLive = await MainActor.run { state.isLiveStream }
        if isLive {
            let name = await MainActor.run { state.currentRadio?.name ?? "" }
            await handleLiveStreamFailure(stationName: name, error: nil)
        } else {
            await MainActor.run { state.playbackState = .error(.timeout) }
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
        let (playbackState, duration, isLiveStream, hasTrack) = await MainActor.run {
            (state.playbackState, state.duration, state.isLiveStream, state.currentTrack != nil)
        }
        guard case .playing = playbackState, !isLiveStream, hasTrack else { return }
        guard elapsed >= 0, duration > 0 else { return }
        await nowPlayingService?.pushPosition(elapsed: elapsed, rate: 1.0, duration: duration)
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
                guard let self else { return }
                Task { await self.handleAudioSessionInterruption(notification) }
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
                // AVAudioSessionRouteDescription is not Sendable — extract the previous
                // route's port types here on the main queue before hopping to the actor.
                let previousOutputs = (notification.userInfo?[AVAudioSessionRouteChangePreviousRouteKey]
                    as? AVAudioSessionRouteDescription)?.outputs.map(\.portType) ?? []
                Task { await self.handleRouteChange(changeReason, previousOutputs: previousOutputs) }
            }
        }
    }

    private func handleAudioSessionInterruption(_ notification: Notification) async {
        guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            // Record route-disconnect interruptions (AirPods in case) before any early
            // return — .ended must never auto-resume those onto the built-in speaker.
            interruptionWasRouteDisconnect = (notification.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionReason.init(rawValue:)) == .routeDisconnected
            let isPlaying = await MainActor.run { state.playbackState == .playing }
            guard isPlaying else { return }
            finalizePlaySegment()
            engine.pause()
            await MainActor.run { state.playbackState = .paused }
            stopProgressTimer()
            await saveSession()
            Logger.player.info("[INTERRUPTION] began — paused playback")

        case .ended:
            let shouldResume = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .flatMap { AVAudioSession.InterruptionOptions(rawValue: $0) }
                .map { $0.contains(.shouldResume) } ?? false
            let wasRouteDisconnect = interruptionWasRouteDisconnect
            interruptionWasRouteDisconnect = false
            Logger.player.info("[INTERRUPTION] ended — shouldResume=\(shouldResume, privacy: .public) routeDisconnect=\(wasRouteDisconnect, privacy: .public)")
            if shouldResume && !wasRouteDisconnect {
                await resume()
            } else {
                Logger.player.info("[INTERRUPTION] ended — staying paused")
            }

        @unknown default:
            break
        }
    }

    // internal: accessible from tests via @testable import
    func handleRouteChange(
        _ reason: AVAudioSession.RouteChangeReason,
        previousOutputs: [AVAudioSession.Port] = []
    ) async {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
            .map { $0.portType.rawValue }
            .joined(separator: ",")
        Logger.player.info("[ROUTE] routeChange reason=\(reason.logDescription, privacy: .public) outputs=[\(outputs, privacy: .public)]")

        switch reason {
        case .oldDeviceUnavailable:
            // Personal listening device went away (AirPods in case, headphones unplugged).
            // Do NOT gate on .playing — the routeDisconnected interruption (iOS 17+) may
            // already have flipped playbackState to .paused while the engine and session
            // are still primed to resume on the speaker. pause() is idempotent and also
            // deactivates the session, which is what actually prevents speaker playback.
            guard previousOutputs.isEmpty
                || PlayerService.isPersonalAudioRoute(portTypes: previousOutputs) else { break }
            let hasActiveTrack = await MainActor.run {
                state.currentTrack != nil && state.playbackState != .idle
            }
            if hasActiveTrack { await pause() }

        case .newDeviceAvailable, .routeConfigurationChange:
            try? AVAudioSession.sharedInstance().setActive(true)

        default:
            break
        }
    }
}

// MARK: - AudioEngineBridge

/// Bridges the neutral `AudioEngineDelegate` callbacks (on the engine's callback thread) onto the
/// `PlayerService` actor. The concrete engine already maps its own
/// callbacks into the neutral events.
nonisolated final class AudioEngineBridge: AudioEngineDelegate, @unchecked Sendable {
    weak var service: PlayerService?

    func audioEngineDidChangeState(_ state: AudioEngineState) {
        guard let service else { return }
        Task { await service.handleEngineState(state) }
    }

    func audioEngineDidReachEndOfTrack() {
        guard let service else { return }
        Task { await service.handleEndOfTrack() }
    }

    func audioEngineDidError(_ message: String) {
        guard let service else { return }
        Task { await service.handleEngineError(message) }
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
