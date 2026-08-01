import Foundation
import Synchronization
import Testing
@testable import Minidisc

private nonisolated final class SyncEventRecorder: @unchecked Sendable {
    private let events = Mutex<[String]>([])

    func append(_ event: String) {
        events.withLock { $0.append(event) }
    }

    var snapshot: [String] {
        events.withLock { $0 }
    }
}

private actor ControlledSyncOperation {
    private var continuation: CheckedContinuation<Void, any Error>?
    private var callCount = 0
    private var didStart = false
    private var didCancel = false
    private var didFinish = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var callCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []

    func run(calendar: Calendar) async throws -> Bool {
        _ = calendar
        callCount += 1
        didStart = true
        var pendingCallCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
        for (target, waiter) in callCountWaiters {
            if callCount >= target {
                waiter.resume()
            } else {
                pendingCallCountWaiters.append((target, waiter))
            }
        }
        callCountWaiters = pendingCallCountWaiters
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }

        defer {
            didFinish = true
            let waiters = finishWaiters
            finishWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                self.continuation = continuation
            }
        }, onCancel: {
            Task { await self.cancel() }
        })
        return true
    }

    func waitUntilStarted() async {
        if didStart { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func waitUntilCallCount(_ target: Int) async {
        guard callCount < target else { return }
        await withCheckedContinuation { continuation in
            callCountWaiters.append((target, continuation))
        }
    }

    func waitUntilCancelled() async {
        if didCancel { return }
        await withCheckedContinuation { cancellationWaiters.append($0) }
    }

    func waitUntilFinished() async {
        if didFinish { return }
        await withCheckedContinuation { finishWaiters.append($0) }
    }

    func complete() {
        let pending = continuation
        continuation = nil
        pending?.resume()
    }

    func calls() -> Int {
        callCount
    }

    func wasCancelled() -> Bool {
        didCancel
    }

    private func cancel() {
        didCancel = true
        let waiters = cancellationWaiters
        cancellationWaiters.removeAll()
        waiters.forEach { $0.resume() }
        let pending = continuation
        continuation = nil
        pending?.resume(throwing: CancellationError())
    }
}

@Suite("Background sync coordination")
struct BackgroundSyncCoordinatorTests {
    @Test("the next request is scheduled before framework completion, exactly once")
    func completionOrderingAndSingleClaim() async {
        let events = SyncEventRecorder()
        let completion = BackgroundTaskCompletion { success in
            events.append("completed:\(success)")
        }

        let successfulClaims = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    completion.complete(success: true) {
                        events.append("scheduled")
                    }
                }
            }
            var count = 0
            for await claimed in group where claimed {
                count += 1
            }
            return count
        }

        #expect(successfulClaims == 1)
        #expect(events.snapshot == ["scheduled", "completed:true"])
    }

    @Test("cold-start and background callers share one in-flight operation")
    func concurrentRunsAreDeduplicated() async {
        let operation = ControlledSyncOperation()
        let coordinator = BackgroundSyncCoordinator { calendar in
            try await operation.run(calendar: calendar)
        }

        let coldStart = Task {
            await coordinator.run(calendar: .current)
        }
        await operation.waitUntilStarted()

        let background = Task {
            await coordinator.run(calendar: .current)
        }
        await coordinator.waitUntilWaiterCount(2)
        await operation.complete()

        let coldStartResult = await coldStart.value
        let backgroundResult = await background.value
        let operationCalls = await operation.calls()

        #expect(coldStartResult)
        #expect(backgroundResult)
        #expect(operationCalls == 1)
    }

    @Test("cancelling one waiter preserves work needed by another")
    func cancellingOneWaiterKeepsPhysicalRunAlive() async {
        let operation = ControlledSyncOperation()
        let coordinator = BackgroundSyncCoordinator { calendar in
            try await operation.run(calendar: calendar)
        }
        let coldStart = Task {
            await coordinator.run(calendar: .current)
        }
        await operation.waitUntilStarted()

        let background = Task {
            await coordinator.run(calendar: .current)
        }
        await coordinator.waitUntilWaiterCount(2)

        background.cancel()
        let backgroundResult = await background.value

        let remainingWaiters = await coordinator.waiterCount()
        let operationWasCancelled = await operation.wasCancelled()
        let operationCalls = await operation.calls()
        #expect(!backgroundResult)
        #expect(remainingWaiters == 1)
        #expect(!operationWasCancelled)
        #expect(operationCalls == 1)

        await operation.complete()
        #expect(await coldStart.value)
    }

    @Test("cancelling the final waiter cancels and retires the physical run")
    func cancellingFinalWaiterCancelsPhysicalRun() async {
        let operation = ControlledSyncOperation()
        let coordinator = BackgroundSyncCoordinator { calendar in
            try await operation.run(calendar: calendar)
        }
        let waiter = Task {
            await coordinator.run(calendar: .current)
        }

        await operation.waitUntilStarted()
        await coordinator.waitUntilWaiterCount(1)
        waiter.cancel()

        let result = await waiter.value
        await operation.waitUntilCancelled()
        await operation.waitUntilFinished()
        await coordinator.waitUntilIdle()

        #expect(!result)
        #expect(await operation.wasCancelled())
        #expect(await operation.calls() == 1)
        #expect(await coordinator.waiterCount() == 0)
    }

    @Test("a caller arriving after final-waiter cancellation starts a fresh run")
    func callerAfterFinalCancellationStartsFreshRun() async {
        let operation = ControlledSyncOperation()
        let coordinator = BackgroundSyncCoordinator { calendar in
            try await operation.run(calendar: calendar)
        }

        let cancelledWaiter = Task {
            await coordinator.run(calendar: .current)
        }
        await operation.waitUntilCallCount(1)
        await coordinator.waitUntilWaiterCount(1)
        cancelledWaiter.cancel()
        #expect(!(await cancelledWaiter.value))
        await operation.waitUntilCancelled()
        await operation.waitUntilFinished()
        await coordinator.waitUntilIdle()

        let replacementWaiter = Task {
            await coordinator.run(calendar: .current)
        }
        await operation.waitUntilCallCount(2)
        await coordinator.waitUntilWaiterCount(1)
        await operation.complete()

        #expect(await replacementWaiter.value)
        #expect(await operation.calls() == 2)
    }
}
