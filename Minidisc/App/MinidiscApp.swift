import SwiftUI
import SwiftData
import OSLog
import Foundation
import BackgroundTasks

@main
struct MinidiscApp: App {
    @State private var container: AppContainer?
    @Environment(\.scenePhase) private var scenePhase

    private nonisolated static let backgroundSyncCoordinator = BackgroundSyncCoordinator()

    init() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: "app.minidisc.wrapped.monthly-update",
            using: nil,
            launchHandler: Self.handleWrappedUpdateBackgroundTask
        )
    }

    /// `BGTaskScheduler` invokes a handler registered with `queue: nil` on a framework-owned queue.
    /// Keeping the handler outside the default-MainActor `App` context prevents Swift 6 from
    /// inserting a main-executor precondition at the callback entry point.
    private nonisolated static func handleWrappedUpdateBackgroundTask(_ task: BGTask) {
        guard let processingTask = task as? BGProcessingTask else {
            task.setTaskCompleted(success: false)
            return
        }
        let completion = BackgroundTaskCompletion(task: processingTask)
        let workTask = Task {
            let syncSucceeded = await backgroundSyncCoordinator.run(calendar: .current)
            let expired = Task.isCancelled
            _ = completion.complete(success: syncSucceeded && !expired) {
                if expired {
                    Logger.wrapped.warning("BGTask expired — rescheduling for tomorrow")
                }
                scheduleWrappedUpdate()
            }
        }
        processingTask.expirationHandler = {
            // The work task completes the BGTask after its waiter has been removed
            // from the coordinator. This preserves an in-flight cold-start waiter,
            // while still cancelling the physical run when this was the last waiter.
            workTask.cancel()
        }
    }

    nonisolated static func scheduleWrappedUpdate() {
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
                let newContainer: AppContainer
                do {
                    newContainer = try AppContainer()
                } catch {
                    Logger.boot.fault("AppContainer initialization failed: \(error, privacy: .public)")
                    return
                }
                await newContainer.setup()
                // Start reachability before the UI is interactive so serverState.isOnline
                // is corrected from its optimistic default before any view loads data.
                newContainer.networkMonitor.start(
                    serverState: newContainer.serverState,
                    streamSettings: newContainer.streamSettings,
                    playerService: newContainer.playerService
                )
                await newContainer.nowPlayingService.start()
                AppContainer.invalidateCoverArtCacheIfNeeded(artworkCache: newContainer.artworkImageCache)
                if let sweepTask = AppContainer.sweepLegacyCoverArtFiles() {
                    newContainer.retainLifecycleTask(sweepTask)
                }
                let modelContainer = newContainer.modelContainer
                let audioStreamCache = newContainer.audioStreamCache
                newContainer.retainLifecycleTask(Task { [modelContainer, audioStreamCache] in
                    await AppContainer.migrateAudioExtensionsIfNeeded(
                        modelContainer: modelContainer,
                        audioStreamCache: audioStreamCache
                    )
                })
                newContainer.retainLifecycleTask(Task { [modelContainer] in
                    await AppContainer.migrateM4AFaststartIfNeeded(
                        modelContainer: modelContainer
                    )
                })
                container = newContainer
                // loadPersistedState must complete before restoreSession so the active
                // server is known when prepareCurrentTrackForRestoration resolves the URL.
                await newContainer.serverService.loadPersistedState()
                await newContainer.playerService.restoreSession()
                let downloadService = newContainer.downloadService
                newContainer.retainLifecycleTask(Task { [modelContainer, downloadService] in
                    await runCoverArtGarbageCollection(
                        modelContainer: modelContainer,
                        downloadService: downloadService
                    )
                })
                await MinidiscApp.backgroundSyncCoordinator.configure(
                    wrappedService: newContainer.wrappedPlaylistService,
                    moodService: newContainer.moodPlaylistService,
                    serverState: newContainer.serverState
                )
                // Cold start and BGProcessing share one deduplicated coordinator run.
                // This task captures only the process-lifetime coordinator, avoiding a
                // container → lifecycle task → container retention cycle.
                newContainer.retainLifecycleTask(Task {
                    _ = await BackgroundActivity.run("playlist-sync") {
                        await MinidiscApp.backgroundSyncCoordinator.run(calendar: .current)
                    }
                })
                MinidiscApp.scheduleWrappedUpdate()
                Logger.boot.info("App services ready")
            }
            .task(id: container?.serverState.isOnline) {
                guard let c = container, c.serverState.isOnline else { return }
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
    private func runCoverArtGarbageCollection(
        modelContainer: ModelContainer,
        downloadService: any DownloadServiceProtocol
    ) async {
        let context = modelContainer.mainContext
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

        await downloadService.garbageCollectOrphanedCovers(referencedIds: referencedIds)
    }

}
