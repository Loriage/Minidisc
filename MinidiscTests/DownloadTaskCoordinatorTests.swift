import Foundation
import Testing
@testable import Minidisc

private actor ControlledDownloadOperation {
    private var continuation: CheckedContinuation<Void, any Error>?
    private var started = false
    private var cancelled = false
    private var finished = false
    private var invocationCount = 0
    private var startObservers: [CheckedContinuation<Void, Never>] = []
    private var callCountObservers: [(Int, CheckedContinuation<Void, Never>)] = []
    private var cancellationObservers: [CheckedContinuation<Void, Never>] = []
    private var finishObservers: [CheckedContinuation<Void, Never>] = []

    func run() async throws {
        invocationCount += 1
        var remainingCallCountObservers: [(Int, CheckedContinuation<Void, Never>)] = []
        for (target, observer) in callCountObservers {
            if invocationCount >= target {
                observer.resume()
            } else {
                remainingCallCountObservers.append((target, observer))
            }
        }
        callCountObservers = remainingCallCountObservers
        started = true
        startObservers.forEach { $0.resume() }
        startObservers.removeAll()

        defer {
            finished = true
            finishObservers.forEach { $0.resume() }
            finishObservers.removeAll()
        }

        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                self.continuation = continuation
            }
        }, onCancel: {
            Task { await self.cancel() }
        })
    }

    func complete() {
        let pending = continuation
        continuation = nil
        pending?.resume()
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startObservers.append($0) }
    }

    func waitUntilCallCount(_ target: Int) async {
        guard invocationCount < target else { return }
        await withCheckedContinuation { continuation in
            callCountObservers.append((target, continuation))
        }
    }

    func waitUntilCancelled() async {
        guard !cancelled else { return }
        await withCheckedContinuation { cancellationObservers.append($0) }
    }

    func waitUntilFinished() async {
        guard !finished else { return }
        await withCheckedContinuation { finishObservers.append($0) }
    }

    func wasCancelled() -> Bool {
        cancelled
    }

    func calls() -> Int {
        invocationCount
    }

    private func cancel() {
        cancelled = true
        cancellationObservers.forEach { $0.resume() }
        cancellationObservers.removeAll()

        let pending = continuation
        continuation = nil
        pending?.resume(throwing: CancellationError())
    }
}

@Suite("Shared download task coordinator")
struct DownloadTaskCoordinatorTests {
    @Test("Cancelling one waiter does not cancel a transfer needed by another waiter")
    func cancellingOneWaiterKeepsSharedTransferAlive() async throws {
        let coordinator = SharedDownloadTaskCoordinator()
        let operation = ControlledDownloadOperation()
        let key = "song::server"

        let first = Task {
            try await coordinator.run(key: key) {
                try await operation.run()
            }
        }
        await operation.waitUntilStarted()

        let second = Task {
            try await coordinator.run(key: key) {
                try await operation.run()
            }
        }
        await coordinator.waitUntilWaiterCount(2, for: key)

        second.cancel()
        await #expect(throws: CancellationError.self) {
            try await second.value
        }

        #expect(await coordinator.waiterCount(for: key) == 1)
        #expect(await operation.calls() == 1)
        #expect(await operation.wasCancelled() == false)

        await operation.complete()
        try await first.value
        #expect(await coordinator.contains(key) == false)
    }

    @Test("Cancelling the final waiter cancels and retires the physical transfer")
    func cancellingFinalWaiterCancelsTransfer() async {
        let coordinator = SharedDownloadTaskCoordinator()
        let operation = ControlledDownloadOperation()
        let key = "song::server"

        let waiter = Task {
            try await coordinator.run(key: key) {
                try await operation.run()
            }
        }
        await operation.waitUntilStarted()
        await coordinator.waitUntilWaiterCount(1, for: key)

        waiter.cancel()
        await #expect(throws: CancellationError.self) {
            try await waiter.value
        }
        await operation.waitUntilCancelled()
        await operation.waitUntilFinished()
        await coordinator.waitUntilIdle(for: key)

        #expect(await operation.calls() == 1)
        #expect(await coordinator.contains(key) == false)
    }

    @Test("A caller after final-waiter cancellation starts a fresh transfer")
    func callerAfterFinalCancellationStartsFreshTransfer() async throws {
        let coordinator = SharedDownloadTaskCoordinator()
        let operation = ControlledDownloadOperation()
        let key = "song::server"

        let cancelledWaiter = Task {
            try await coordinator.run(key: key) {
                try await operation.run()
            }
        }
        await operation.waitUntilCallCount(1)
        await coordinator.waitUntilWaiterCount(1, for: key)
        cancelledWaiter.cancel()
        await #expect(throws: CancellationError.self) {
            try await cancelledWaiter.value
        }
        await operation.waitUntilCancelled()
        await operation.waitUntilFinished()
        await coordinator.waitUntilIdle(for: key)

        let replacementWaiter = Task {
            try await coordinator.run(key: key) {
                try await operation.run()
            }
        }
        await operation.waitUntilCallCount(2)
        await coordinator.waitUntilWaiterCount(1, for: key)
        await operation.complete()

        try await replacementWaiter.value
        #expect(await operation.calls() == 2)
    }

    @Test("Only parent or remove-all cancellation propagates out of grouped best-effort work")
    func groupedCancellationPolicy() {
        #expect(!DownloadCancellationPolicy.shouldPropagate(
            parentTaskIsCancelled: false,
            removingAll: false
        ))
        #expect(DownloadCancellationPolicy.shouldPropagate(
            parentTaskIsCancelled: true,
            removingAll: false
        ))
        #expect(DownloadCancellationPolicy.shouldPropagate(
            parentTaskIsCancelled: false,
            removingAll: true
        ))
    }
}
