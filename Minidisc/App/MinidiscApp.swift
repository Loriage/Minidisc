import SwiftUI
import SwiftData
import OSLog
import Foundation
import BackgroundTasks

@main
struct MinidiscApp: App {
    @UIApplicationDelegateAdaptor(MinidiscAppDelegate.self) private var appDelegate
    @State private var launchState: AppLaunchState = .launching
    @State private var launchAttempt = 1
    @Environment(\.scenePhase) private var scenePhase
    private let playbackDiagnostics = PlaybackDiagnostics()

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
            AppLaunchContent(state: launchState, retryAction: retryLaunch)
                .task(id: launchAttempt) {
                    await launchIfNeeded()
                }
                .task(id: activeContainer?.serverState.libraryIndexPreparationSnapshot) {
                    guard let container = activeContainer else { return }
                    await container.downloadService.restorePendingDownloads()
                    let snapshot = container.serverState.libraryIndexPreparationSnapshot
                    guard snapshot.isOnline else { return }
                    await container.listenBrainzService.flushOfflineQueue()
                    do {
                        try await container.libraryCatalog.prepare(
                            automaticRefreshAllowed: snapshot.automaticRefreshAllowed
                        )
                    } catch is CancellationError {
                        // The active server or connectivity changed.
                    } catch {
                        // The persistent cache remains usable; a later reconnect or manual
                        // refresh retries only the entity scans that never completed.
                        Logger.library.debug(
                            "Library index preparation deferred: \(error, privacy: .public)"
                        )
                    }
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .inactive, let container = activeContainer {
                Task { await container.playerService.saveCurrentPosition() }
                Logger.session.info("App inactive — position flushed (iOS kill guard)")
            }
            guard newPhase == .background, let container = activeContainer else { return }
            guard container.playerState.currentRadio == nil,
                  container.playerState.currentTrack != nil else {
                Logger.session.info("App backgrounded during radio — preserving the last music session")
                return
            }
            let snapshot = SessionPayload(
                currentIndex: container.playerState.currentIndex,
                currentPosition: container.playerState.position,
                queue: container.playerState.queue,
                currentTrack: container.playerState.currentTrack,
                repeatMode: container.playerState.repeatMode
            )
            Task { await container.sessionService.save(playerState: snapshot) }
            Logger.session.info("App backgrounded — session flushed")
        }
    }

    private var activeContainer: AppContainer? {
        guard case .ready(let container) = launchState else { return nil }
        return container
    }

    private func retryLaunch() {
        guard case .failed = launchState else { return }
        launchState = .launching
        launchAttempt += 1
    }

    private func launchIfNeeded() async {
        guard case .launching = launchState else { return }
        playbackDiagnostics.record(.application(.launchStarted(attempt: launchAttempt)))

        let newContainer: AppContainer
        do {
            newContainer = try AppContainer(playbackDiagnostics: playbackDiagnostics)
        } catch {
            let failure = error as NSError
            Logger.boot.fault(
                "AppContainer initialization failed: domain=\(failure.domain, privacy: .public) code=\(failure.code, privacy: .public)"
            )
            playbackDiagnostics.record(
                .application(.launchFailed(errorDomain: failure.domain, errorCode: failure.code))
            )
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
            let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
            let report = playbackDiagnostics.makeReport(
                context: PlaybackDiagnostics.ReportContext(
                    appVersion: version,
                    appBuild: build,
                    operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                    playbackStatus: .idle,
                    isPlaybackAvailable: false,
                    networkPath: nil,
                    connectionVersion: nil
                )
            )
            launchState = .failed(diagnosticReport: report)
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
            await AppContainer.migrateM4AFaststartIfNeeded(modelContainer: modelContainer)
        })
        // The active server must be loaded before session restoration resolves its media URL.
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
        newContainer.retainLifecycleTask(Task {
            _ = await BackgroundActivity.run("playlist-sync") {
                await MinidiscApp.backgroundSyncCoordinator.run(calendar: .current)
            }
        })
        MinidiscApp.scheduleWrappedUpdate()
        launchState = .ready(newContainer)
        playbackDiagnostics.record(.application(.servicesReady))
        Logger.boot.info("App services ready")
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

private enum AppLaunchState {
    case launching
    case ready(AppContainer)
    case failed(diagnosticReport: String)
}

private struct AppLaunchContent: View {
    let state: AppLaunchState
    let retryAction: () -> Void

    var body: some View {
        switch state {
        case .launching:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .ready(let container):
            RootView()
                // Toast content renders cover art, so these environments must wrap the overlay too.
                .toastOverlay()
                .environment(\.appContainer, container)
                .environment(container.dominantColorExtractor)
                .environment(container.artworkImageCache)
                .modelContainer(container.modelContainer)
                .environment(container.toastService)

        case .failed(let diagnosticReport):
            AppLaunchFailureView(
                diagnosticReport: diagnosticReport,
                retryAction: retryAction
            )
        }
    }
}

private struct AppLaunchFailureView: View {
    let diagnosticReport: String
    let retryAction: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Unable to Load", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            Text("Minidisc couldn't open its local data. You can try again without restarting the app.")
        } actions: {
            ShareLink(item: diagnosticReport) {
                Label("Share Diagnostics", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
            .tint(.primary)

            Button("Retry", action: retryAction)
                .buttonStyle(.borderedProminent)
                .tint(MinidiscColors.accent)
        }
    }
}
