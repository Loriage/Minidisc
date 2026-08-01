import BackgroundTasks
import Foundation
import OSLog
import Synchronization

/// Owns the dependencies used by the BackgroundTasks callback.
///
/// The scheduler callback can run outside `MainActor`; storing the dependencies
/// in an actor establishes a real synchronization boundary instead of relying on
/// write-once `nonisolated(unsafe)` globals.
actor BackgroundSyncCoordinator {
    private typealias SyncOperation = @Sendable (Calendar) async throws -> Bool

    private struct ActiveRun {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<Bool, Never>]
    }

    private struct WaiterCountObserver {
        let target: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var syncOperation: SyncOperation?
    private var activeRun: ActiveRun?
    private var waiterCountObservers: [WaiterCountObserver] = []
    private var idleObservers: [CheckedContinuation<Void, Never>] = []

    init() {}

    /// Test-only seam that keeps deduplication and cancellation independently
    /// verifiable without constructing the full application service graph.
    init(operation: @escaping @Sendable (Calendar) async throws -> Bool) {
        syncOperation = operation
    }

    func configure(
        wrappedService: WrappedPlaylistService,
        moodService: MoodPlaylistService,
        serverState: ServerState
    ) {
        syncOperation = { calendar in
            try Task.checkCancellation()
            let serverId = await MainActor.run {
                serverState.activeServer?.id.uuidString
            }
            try Task.checkCancellation()
            guard let serverId else { return false }

            try await wrappedService.handleYearTransitionIfNeededCancellable(
                serverId: serverId,
                calendar: calendar
            )
            let wrappedResult = try await wrappedService.runYearlyPlaylistSyncIfNeededCancellable(
                serverId: serverId,
                calendar: calendar
            )
            Logger.wrapped.info(
                "Playlist sync result: \(String(describing: wrappedResult), privacy: .public)"
            )

            try Task.checkCancellation()
            let moodResult = try await moodService.runWeeklySyncIfNeededCancellable(
                serverId: serverId,
                calendar: calendar
            )
            Logger.moodPlaylists.info(
                "Playlist sync result: \(String(describing: moodResult), privacy: .public)"
            )
            try Task.checkCancellation()

            if case .serverError = wrappedResult {
                return false
            }
            return true
        }
    }

    /// Both cold-start and BGProcessing entry points call this method. The first
    /// caller owns the work; concurrent callers await the same task.
    func run(calendar: Calendar) async -> Bool {
        guard !Task.isCancelled else { return false }

        guard let syncOperation else { return false }
        let runID: UUID
        if let activeRun {
            runID = activeRun.id
        } else {
            let id = UUID()
            let task = Task {
                let result: Bool
                do {
                    try Task.checkCancellation()
                    result = try await syncOperation(calendar)
                } catch is CancellationError {
                    Logger.wrapped.debug("Playlist sync cancelled")
                    result = false
                } catch {
                    Logger.wrapped.error(
                        "Playlist sync failed unexpectedly: \(error, privacy: .public)"
                    )
                    result = false
                }
                self.complete(runID: id, result: result)
            }
            activeRun = ActiveRun(id: id, task: task, waiters: [:])
            runID = id
        }

        let waiterID = UUID()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                guard var run = activeRun, run.id == runID else {
                    continuation.resume(returning: false)
                    return
                }
                run.waiters[waiterID] = continuation
                activeRun = run
                resumeSatisfiedWaiterCountObservers()

                // Cancellation can race between the initial check and waiter registration.
                if Task.isCancelled {
                    cancelWaiter(runID: runID, waiterID: waiterID)
                }
            }
        }, onCancel: {
            Task {
                await self.cancelWaiter(runID: runID, waiterID: waiterID)
            }
        })
    }

    /// Deterministic synchronization seams for cancellation tests.
    func waiterCount() -> Int {
        activeRun?.waiters.count ?? 0
    }

    func waitUntilWaiterCount(_ target: Int) async {
        guard (activeRun?.waiters.count ?? 0) < target else { return }
        await withCheckedContinuation { continuation in
            waiterCountObservers.append(
                WaiterCountObserver(target: target, continuation: continuation)
            )
        }
    }

    func waitUntilIdle() async {
        guard activeRun != nil else { return }
        await withCheckedContinuation { idleObservers.append($0) }
    }

    private func cancelWaiter(runID: UUID, waiterID: UUID) {
        guard var run = activeRun,
              run.id == runID,
              let continuation = run.waiters.removeValue(forKey: waiterID)
        else {
            return
        }

        continuation.resume(returning: false)
        if run.waiters.isEmpty {
            // Retire the logical run before cancelling its task. A new caller
            // arriving while the old operation unwinds must start fresh rather
            // than attach itself to an already-cancelled task.
            activeRun = nil
            resumeObserversAfterRunRetired()
            run.task.cancel()
        } else {
            activeRun = run
        }
    }

    private func complete(runID: UUID, result: Bool) {
        guard let run = activeRun, run.id == runID else { return }
        activeRun = nil

        run.waiters.values.forEach { $0.resume(returning: result) }
        resumeObserversAfterRunRetired()
    }

    private func resumeObserversAfterRunRetired() {
        waiterCountObservers.forEach { $0.continuation.resume() }
        waiterCountObservers.removeAll()
        idleObservers.forEach { $0.resume() }
        idleObservers.removeAll()
    }

    private func resumeSatisfiedWaiterCountObservers() {
        let count = activeRun?.waiters.count ?? 0
        var remaining: [WaiterCountObserver] = []
        for observer in waiterCountObservers {
            if count >= observer.target {
                observer.continuation.resume()
            } else {
                remaining.append(observer)
            }
        }
        waiterCountObservers = remaining
    }
}

/// Ensures a `BGTask` is completed exactly once even if normal completion races
/// with the expiration handler.
nonisolated final class BackgroundTaskCompletion: @unchecked Sendable {
    private let task: BGTask?
    private let testCompletion: (@Sendable (Bool) -> Void)?
    private let completed = Mutex(false)

    init(task: BGTask) {
        self.task = task
        testCompletion = nil
    }

    init(testCompletion: @escaping @Sendable (Bool) -> Void) {
        task = nil
        self.testCompletion = testCompletion
    }

    /// Returns `true` only to the racing caller that claimed completion.
    ///
    /// `beforeCompletion` deliberately runs after the atomic claim but before
    /// `BGTask.setTaskCompleted`. BGTaskScheduler may suspend the process as soon
    /// as completion is reported, so the next request must be submitted first.
    /// Neither caller code nor the framework is invoked while the mutex is held.
    func complete(success: Bool, beforeCompletion: () -> Void) -> Bool {
        let claimed = completed.withLock { completed in
            guard !completed else { return false }
            completed = true
            return true
        }
        guard claimed else { return false }

        beforeCompletion()
        if let task {
            task.setTaskCompleted(success: success)
        } else {
            testCompletion?(success)
        }
        return true
    }
}
