// Minidisc — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftData
import OSLog
import Foundation
import BackgroundTasks

@main
struct MinidiscApp: App {
    @State private var container: AppContainer?
    @Environment(\.scenePhase) private var scenePhase

    // Statics for BGTask handler access — set once after AppContainer init.
    // nonisolated(unsafe) is intentional: the BGTask closure runs off-actor;
    // these are written once on MainActor and read in a non-isolated context.
    nonisolated(unsafe) private static var _bgTaskService: WrappedPlaylistService?
    nonisolated(unsafe) private static var _bgTaskServerState: ServerState?
    nonisolated(unsafe) private static var _bgTaskMoodService: MoodPlaylistService?

    init() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: "app.minidisc.wrapped.monthly-update",
            using: nil
        ) { task in
            guard let processingTask = task as? BGProcessingTask,
                  let service = MinidiscApp._bgTaskService,
                  let serverState = MinidiscApp._bgTaskServerState else {
                task.setTaskCompleted(success: false)
                return
            }
            let workTask = Task {
                let serverId = await MainActor.run { serverState.activeServer?.id.uuidString }
                guard let serverId else {
                    processingTask.setTaskCompleted(success: false)
                    return
                }
                let result = await service.runYearlyPlaylistSyncIfNeeded(serverId: serverId, calendar: .current)
                Logger.wrapped.info("BGTask result: \(String(describing: result), privacy: .public)")
                // Mood playlists ride along on this task rather than declaring a second identifier:
                // it already wakes roughly daily, which is the right granularity for "has Wednesday
                // passed yet", and a new identifier would need an Info.plist entry to match.
                if let moods = MinidiscApp._bgTaskMoodService {
                    let moodResult = await moods.runWeeklySyncIfNeeded(serverId: serverId, calendar: .current)
                    Logger.moodPlaylists.info("BGTask result: \(String(describing: moodResult), privacy: .public)")
                }
                processingTask.setTaskCompleted(success: true)
                MinidiscApp.scheduleWrappedUpdate()
            }
            processingTask.expirationHandler = {
                workTask.cancel()
                Logger.wrapped.warning("BGTask expired — rescheduling for tomorrow")
                MinidiscApp.scheduleWrappedUpdate()
            }
        }
    }

    static func scheduleWrappedUpdate() {
        let request = BGProcessingTaskRequest(identifier: "app.minidisc.wrapped.monthly-update")
        request.requiresNetworkConnectivity = true
        request.earliestBeginDate = Date().addingTimeInterval(24 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let container {
                    RootView()
                        // .toastOverlay() must be the INNERMOST modifier: a toast pill now renders a
                        // CoverArtView, which reads @Environment(ArtworkImageCache.self) / appContainer.
                        // An overlay's content only inherits environments applied AFTER the overlay
                        // modifier (envs applied to the primary content below it do NOT reach the
                        // overlay's own view). So the env injections must sit below .toastOverlay().
                        .toastOverlay()
                        .environment(\.appContainer, container)
                        .environment(container.dominantColorExtractor)
                        .environment(container.artworkImageCache)
                        .modelContainer(container.modelContainer)
                        .environment(container.toastService)
                } else {
                    ProgressView()
                }
            }
            .tint(MinidiscColors.accent)
            .task {
                guard container == nil else { return }
                Logger.boot.notice("🟡 AppContainer init start")
                guard let newContainer = try? AppContainer() else { return }
                Logger.boot.notice("🟡 setup() start")
                await newContainer.setup()
                // Start reachability before the UI is interactive so serverState.isOnline
                // is corrected from its optimistic default before any view loads data.
                newContainer.networkMonitor.start(serverState: newContainer.serverState)
                Logger.boot.notice("🟡 setup() done — nowPlayingService.start()")
                await newContainer.nowPlayingService.start()
                AppContainer.invalidateCoverArtCacheIfNeeded(artworkCache: newContainer.artworkImageCache)
                AppContainer.sweepLegacyCoverArtFiles()
                Task { await AppContainer.migrateAudioExtensionsIfNeeded(modelContainer: newContainer.modelContainer, audioStreamCache: newContainer.audioStreamCache) }
                Task { await AppContainer.migrateM4AFaststartIfNeeded(modelContainer: newContainer.modelContainer) }
                Logger.boot.notice("🟡 container = newContainer (views will render)")
                container = newContainer
                Logger.boot.notice("🟡 loadPersistedState() start")
                // loadPersistedState must complete before restoreSession so the active
                // server is known when prepareCurrentTrackForRestoration resolves the URL.
                await newContainer.serverService.loadPersistedState()
                Logger.boot.notice("🟡 loadPersistedState() done — activeServer = \(String(describing: newContainer.serverState.activeServer?.baseURL), privacy: .public)")
                await newContainer.playerService.restoreSession()
                Task { await runCoverArtGarbageCollection(container: newContainer) }
                // Cold start fallback: primary trigger for Wrapped updates (BGTask is best-effort).
                // Fire-and-forget — must never block app launch.
                Task { await runWrappedUpdate(container: newContainer) }
                Task { await runMoodUpdate(container: newContainer) }
                MinidiscApp._bgTaskService = newContainer.wrappedPlaylistService
                MinidiscApp._bgTaskServerState = newContainer.serverState
                MinidiscApp._bgTaskMoodService = newContainer.moodPlaylistService
                MinidiscApp.scheduleWrappedUpdate()
            }
            .task(id: container?.serverState.isOnline) {
                guard let c = container, c.serverState.isOnline else { return }
                await c.playerService.handleNetworkRestored()
                await c.listenBrainzService.flushOfflineQueue()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .inactive, let c = container {
                Task { await c.playerService.saveCurrentPosition() }
                Logger.session.info("App inactive — position flushed (iOS kill guard)")
            }
            guard newPhase == .background, let c = container else { return }
            guard c.playerState.currentRadio == nil, c.playerState.currentTrack != nil else {
                Logger.session.info("App backgrounded during radio — preserving the last music session")
                return
            }
            let snapshot = SessionPayload(
                currentIndex: c.playerState.currentIndex,
                currentPosition: c.playerState.position,
                queue: c.playerState.queue,
                currentTrack: c.playerState.currentTrack,
                repeatMode: c.playerState.repeatMode
            )
            Task { await c.sessionService.save(playerState: snapshot) }
            Logger.session.info("App backgrounded — session flushed")
        }
    }

    // MARK: - Cover art garbage collection

    @MainActor
    private func runCoverArtGarbageCollection(container: AppContainer) async {
        let context = container.modelContainer.mainContext
        var referencedIds: Set<String> = []

        let albums = (try? context.fetch(FetchDescriptor<DownloadedAlbum>())) ?? []
        for album in albums {
            if let id = album.coverArtId { referencedIds.insert(id) }
        }

        let tracks = (try? context.fetch(FetchDescriptor<DownloadedTrack>())) ?? []
        for track in tracks {
            if let id = track.coverArtId { referencedIds.insert(id) }
        }

        let playlists = (try? context.fetch(FetchDescriptor<DownloadedPlaylist>())) ?? []
        for playlist in playlists {
            if let id = playlist.coverArtId { referencedIds.insert(id) }
        }

        let pinned = (try? context.fetch(FetchDescriptor<PinnedItem>())) ?? []
        for item in pinned {
            if let id = item.coverArtId { referencedIds.insert(id) }
        }

        await container.downloadService.garbageCollectOrphanedCovers(referencedIds: referencedIds)
    }

    // MARK: - Wrapped update

    @MainActor
    private func runWrappedUpdate(container: AppContainer) async {
        guard let serverId = container.serverState.activeServer?.id.uuidString else { return }
        await container.wrappedPlaylistService.handleYearTransitionIfNeeded(serverId: serverId, calendar: .current)
        let result = await container.wrappedPlaylistService.runYearlyPlaylistSyncIfNeeded(serverId: serverId, calendar: .current)
        Logger.wrapped.info("Cold start result: \(String(describing: result), privacy: .public)")
    }

    // MARK: - Mood playlists

    /// Cold-start catch-up for the weekly mood refresh. This, not the BGTask, is what users
    /// actually experience: iOS grants background time at its own discretion, so the refresh lands
    /// on the first launch on or after Wednesday. A no-op on every other launch.
    @MainActor
    private func runMoodUpdate(container: AppContainer) async {
        guard let serverId = container.serverState.activeServer?.id.uuidString else { return }
        // Wrapped in a background assertion because this is the one path that can start with
        // nothing playing: without it, backgrounding the app a second after launch freezes the sync
        // mid-flight. Progress is per-mood, so an interrupted run still resumes where it stopped.
        let result = await BackgroundActivity.run("mood-playlists") {
            await container.moodPlaylistService.runWeeklySyncIfNeeded(serverId: serverId, calendar: .current)
        }
        Logger.moodPlaylists.info("Cold start result: \(String(describing: result), privacy: .public)")
    }
}
