import Foundation
import Testing
import UIKit
@testable import Minidisc

nonisolated private let artworkFixtureData = Data(
    base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAACklEQVQI12NgAAAAAgAB4iG8MwAAAABJRU5ErkJggg=="
)!

private actor ControlledArtworkDataLoader {
    private struct Pending {
        let request: URLRequest
        let continuation: CheckedContinuation<(Data, URLResponse), Error>
    }

    private var pending: [Pending] = []
    private var callCount = 0

    func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        callCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending.append(Pending(request: request, continuation: continuation))
        }
    }

    func completeNext(data: Data, lastModified: String? = nil) {
        guard !pending.isEmpty else { return }
        let pending = pending.removeFirst()
        let response = HTTPURLResponse(
            url: pending.request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: lastModified.map { ["Last-Modified": $0] }
        )!
        pending.continuation.resume(returning: (data, response))
    }

    func calls() -> Int { callCount }
}

private actor ControlledDecodeGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var callCount = 0

    func wait() async {
        callCount += 1
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }

    func calls() -> Int { callCount }
}

private actor CacheCompletionProbe {
    private var completed = false

    func markCompleted() { completed = true }
    func isCompleted() -> Bool { completed }
}

private actor PersistRecorder {
    private var count = 0

    func record() { count += 1 }
    func calls() -> Int { count }
}

private actor BlockingPersistenceStore {
    private var persistedIDs: Set<String> = []
    private var persistContinuation: CheckedContinuation<Void, Never>?
    private var persistStarted = false
    private var removeCount = 0

    func persist(id: String) async {
        persistStarted = true
        await withCheckedContinuation { continuation in
            persistContinuation = continuation
        }
        persistedIDs.insert(id)
    }

    func remove(id: String) {
        removeCount += 1
        persistedIDs.remove(id)
    }

    func resumePersist() {
        persistContinuation?.resume()
        persistContinuation = nil
    }

    func didStartPersisting() -> Bool { persistStarted }
    func removals() -> Int { removeCount }
    func contains(_ id: String) -> Bool { persistedIDs.contains(id) }
}

private actor BlockingRemovalStore {
    private var storedIDs: Set<String>
    private var shouldBlockFirstRemoval = true
    private var removalContinuation: CheckedContinuation<Void, Never>?
    private var removalStarted = false
    private var localLookupCount = 0

    init(storedIDs: Set<String>) {
        self.storedIDs = storedIDs
    }

    func localURL(for id: String) -> URL? {
        localLookupCount += 1
        guard storedIDs.contains(id) else { return nil }
        return FileManager.default.temporaryDirectory.appendingPathComponent("old-cover")
    }

    func remove(id: String) async {
        if shouldBlockFirstRemoval {
            shouldBlockFirstRemoval = false
            removalStarted = true
            await withCheckedContinuation { continuation in
                removalContinuation = continuation
            }
        }
        storedIDs.remove(id)
    }

    func resumeRemoval() {
        removalContinuation?.resume()
        removalContinuation = nil
    }

    func didStartRemoval() -> Bool { removalStarted }
    func localLookups() -> Int { localLookupCount }
}

private actor ArtworkNetworkCounter {
    private var count = 0

    func response(for request: URLRequest) -> (Data, URLResponse) {
        count += 1
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (artworkFixtureData, response)
    }

    func calls() -> Int { count }
}

private actor RevalidationDataLoader {
    private var changedGET: CheckedContinuation<(Data, URLResponse), Error>?
    private var getCount = 0

    func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        if request.httpMethod == "HEAD" {
            return response(for: request, lastModified: "new")
        }

        getCount += 1
        if getCount == 1 {
            return response(for: request, lastModified: "old")
        }
        return try await withCheckedThrowingContinuation { continuation in
            changedGET = continuation
        }
    }

    func completeChangedGET() {
        guard let changedGET else { return }
        self.changedGET = nil
        let url = URL(string: "https://example.com/cover")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Last-Modified": "new"]
        )!
        changedGET.resume(returning: (artworkFixtureData, response))
    }

    func gets() -> Int { getCount }

    private func response(
        for request: URLRequest,
        lastModified: String
    ) -> (Data, URLResponse) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Last-Modified": lastModified]
        )!
        return (artworkFixtureData, response)
    }
}

@MainActor
private func eventuallyArtwork(
    _ condition: @escaping @MainActor () async -> Bool
) async -> Bool {
    for _ in 0..<200 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return false
}

@MainActor
@Suite("ArtworkImageCache concurrency")
struct ArtworkImageCacheConcurrencyTests {
    private func store() -> CoverRevalidationStore {
        CoverRevalidationStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
        )
    }

    @Test("one cancelled waiter returns promptly while the shared load continues")
    func oneCancelledWaiterDoesNotCancelSharedLoad() async {
        let loader = ControlledArtworkDataLoader()
        let probe = CacheCompletionProbe()
        let cache = ArtworkImageCache(
            revalidationStore: store(),
            coverArtURLProvider: { _, _ in URL(string: "https://example.com/cover") },
            dataLoader: { request in try await loader.load(request) },
            imageDecoder: { data, _ in PlatformImage(data: data) }
        )

        let first = Task { await cache.load(coverArtId: "shared") }
        #expect(await eventuallyArtwork { await loader.calls() == 1 })
        let cancelled = Task {
            let result = await cache.load(coverArtId: "shared")
            await probe.markCompleted()
            return result
        }
        #expect(await eventuallyArtwork {
            cache.inFlightWaiterCount(for: "shared") == 2
        })

        cancelled.cancel()
        #expect(await eventuallyArtwork { await probe.isCompleted() })
        #expect(await loader.calls() == 1)

        await loader.completeNext(data: artworkFixtureData, lastModified: "old")
        #expect(await cancelled.value == nil)
        #expect(await first.value != nil)
        #expect(await loader.calls() == 1)
    }

    @Test("invalidation during an uncooperative decode prevents every late commit")
    func invalidationDuringDecodePreventsLateCommit() async {
        let decodeGate = ControlledDecodeGate()
        let persistence = PersistRecorder()
        let cache = ArtworkImageCache(
            revalidationStore: store(),
            coverArtURLProvider: { _, _ in URL(string: "https://example.com/cover") },
            persistCoverOperation: { _, _ in await persistence.record() },
            dataLoader: { request in
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (artworkFixtureData, response)
            },
            imageDecoder: { data, _ in
                await decodeGate.wait()
                return PlatformImage(data: data)
            }
        )

        let load = Task { await cache.load(coverArtId: "stale") }
        #expect(await eventuallyArtwork { await decodeGate.calls() == 1 })

        await cache.invalidate(for: "stale")
        #expect(await load.value == nil)
        await decodeGate.resume()
        #expect(await eventuallyArtwork { cache.completedLoads() == 1 })

        #expect(cache.cachedImage(for: "stale") == nil)
        #expect(await persistence.calls() == 0)
    }

    @Test("explicit invalidation wins against a changed-cover revalidation")
    func invalidationWinsAgainstRevalidation() async {
        let loader = RevalidationDataLoader()
        let revalidationStore = store()
        let cache = ArtworkImageCache(
            revalidationStore: revalidationStore,
            coverArtURLProvider: { _, _ in URL(string: "https://example.com/cover") },
            dataLoader: { request in try await loader.load(request) },
            imageDecoder: { data, _ in PlatformImage(data: data) }
        )
        cache.persistCoversEnabled = false

        #expect(await cache.load(coverArtId: "revalidated") != nil)
        revalidationStore.record(
            id: "revalidated",
            lastModified: "old",
            checkedAt: .distantPast
        )
        #expect(await cache.load(coverArtId: "revalidated") != nil)
        #expect(await eventuallyArtwork { await loader.gets() == 2 })

        await cache.invalidate(for: "revalidated")
        await loader.completeChangedGET()
        #expect(await eventuallyArtwork { cache.completedRevalidations() == 1 })

        #expect(cache.cachedImage(for: "revalidated") == nil)
        #expect(revalidationStore.lastModified(for: "revalidated") == nil)
    }

    @Test("invalidation removes a stale persist that completes after cancellation")
    func invalidationSerializesWithUncooperativePersist() async {
        let disk = BlockingPersistenceStore()
        let cache = ArtworkImageCache(
            revalidationStore: store(),
            coverArtURLProvider: { _, _ in URL(string: "https://example.com/cover") },
            persistCoverOperation: { _, id in await disk.persist(id: id) },
            removeCoverOperation: { id in await disk.remove(id: id) },
            dataLoader: { request in
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (artworkFixtureData, response)
            },
            imageDecoder: { data, _ in PlatformImage(data: data) }
        )

        let load = Task { await cache.load(coverArtId: "persist-race") }
        #expect(await eventuallyArtwork { await disk.didStartPersisting() })
        let invalidation = Task { await cache.invalidate(for: "persist-race") }

        try? await Task.sleep(for: .milliseconds(10))
        #expect(await disk.removals() == 0)
        await disk.resumePersist()

        await invalidation.value
        #expect(await load.value == nil)
        #expect(await disk.removals() == 3)
        #expect(await disk.contains("persist-race@thumb") == false)
    }

    @Test("a load cannot read disk while invalidation is removing the cover")
    func loadWaitsForInvalidationDiskTransaction() async {
        let disk = BlockingRemovalStore(storedIDs: ["disk-race@thumb"])
        let network = ArtworkNetworkCounter()
        let cache = ArtworkImageCache(
            revalidationStore: store(),
            coverArtURLProvider: { _, _ in URL(string: "https://example.com/cover") },
            localCoverURLProvider: { id in await disk.localURL(for: id) },
            removeCoverOperation: { id in await disk.remove(id: id) },
            dataLoader: { request in await network.response(for: request) },
            imageDecoder: { data, _ in PlatformImage(data: data) }
        )
        cache.persistCoversEnabled = false

        let invalidation = Task { await cache.invalidate(for: "disk-race") }
        #expect(await eventuallyArtwork { await disk.didStartRemoval() })
        let load = Task { await cache.load(coverArtId: "disk-race") }

        try? await Task.sleep(for: .milliseconds(10))
        #expect(await disk.localLookups() == 0)
        #expect(await network.calls() == 0)

        await disk.resumeRemoval()
        await invalidation.value
        #expect(await load.value != nil)
        #expect(await disk.localLookups() == 1)
        #expect(await network.calls() == 1)
    }
}
