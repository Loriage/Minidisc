import Testing
@testable import Minidisc

@Suite("CoverFetchGate")
struct CoverFetchGateTests {
    @Test("Cancelling a queued waiter removes it and returns full capacity")
    func cancelledWaiterReturnsCapacity() async throws {
        let gate = CoverFetchGate(limit: 1)
        try await gate.acquire()

        let waiter = Task {
            do {
                try await gate.acquire()
                await gate.release()
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }

        var registered = false
        for _ in 0..<100 {
            if await gate.waitingCount() == 1 {
                registered = true
                break
            }
            await Task.yield()
        }
        #expect(registered)

        waiter.cancel()
        let observedCancellation = await waiter.value
        let remainingWaiters = await gate.waitingCount()
        let availableWhileHeld = await gate.availablePermitCount()

        #expect(observedCancellation)
        #expect(remainingWaiters == 0)
        #expect(availableWhileHeld == 0)

        await gate.release()
        let restoredCapacity = await gate.availablePermitCount()
        #expect(restoredCapacity == 1)
    }
}
