import Testing
import Foundation
@testable import Minidisc

// MARK: - Fixtures

// Minimal valid 1×1 PNG — parseable by both UIImage and NSImage.
private let validImageData: Data = {
    let b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAACklEQVQI12NgAAAAAgAB4iG8MwAAAABJRU5ErkJggg=="
    return Data(base64Encoded: b64)!
}()

private let invalidImageData = Data("not_an_image".utf8)
private let testURL = URL(string: "https://coverartarchive.org/release/test/cover.jpg")!

// MARK: - Mock fetchers

@MainActor
private final class CountingFetcher: ExternalArtworkFetcher {
    private(set) var callCount = 0
    let result: Result<Data, Error>

    init(data: Data) { result = .success(data) }
    init(throwing error: Error) { result = .failure(error) }

    nonisolated func fetchData(from url: URL) async throws -> Data {
        await increment()
        switch result {
        case .success(let data): return data
        case .failure(let error): throw error
        }
    }

    private func increment() { callCount += 1 }
}

private actor DelayedCountingFetcher: ExternalArtworkFetcher {
    private var callCount = 0
    private let data: Data
    private let delay: Duration

    init(data: Data, delay: Duration) {
        self.data = data
        self.delay = delay
    }

    func fetchData(from url: URL) async throws -> Data {
        callCount += 1
        try await Task.sleep(for: delay)
        return data
    }

    func calls() -> Int {
        callCount
    }
}

private actor ControlledArtworkFetcher: ExternalArtworkFetcher {
    private var continuation: CheckedContinuation<Data, Error>?
    private var callCount = 0
    private var returnCount = 0

    func fetchData(from url: URL) async throws -> Data {
        callCount += 1
        let data = try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
        returnCount += 1
        return data
    }

    func complete(with data: Data) {
        continuation?.resume(returning: data)
        continuation = nil
    }

    func calls() -> Int { callCount }
    func returns() -> Int { returnCount }
}

private actor CompletionProbe {
    private var completed = false

    func markCompleted() { completed = true }
    func isCompleted() -> Bool { completed }
}

// MARK: - Helpers

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func makeCache(
    dir: URL,
    fetcher: (any ExternalArtworkFetcher)? = nil,
    ttl: TimeInterval = 90 * 24 * 3600,
    maxSizeBytes: Int64 = 100 * 1024 * 1024,
    maxMemoryEntries: Int = 30
) -> ExternalArtworkCache {
    ExternalArtworkCache(
        cacheDirectory: dir,
        fetcher: fetcher,
        ttl: ttl,
        maxSizeBytes: maxSizeBytes,
        maxMemoryEntries: maxMemoryEntries
    )
}

private func eventually(
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    for _ in 0..<200 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return false
}

// MARK: - Tests

@Suite("ExternalArtworkCache")
struct ExternalArtworkCacheTests {

    // MARK: Memory cache

    @Test("memory cache hit prevents second network call")
    func memoryCacheHitSkipsNetwork() async throws {
        let dir = try makeTempDir()
        let fetcher = CountingFetcher(data: validImageData)
        let cache = makeCache(dir: dir, fetcher: fetcher)

        _ = await cache.image(for: testURL)   // network fetch + memory store
        _ = await cache.image(for: testURL)   // memory hit

        #expect(fetcher.callCount == 1)
    }

    @Test("concurrent requests for one URL share disk and network work")
    func concurrentRequestsShareOnePipeline() async throws {
        let dir = try makeTempDir()
        let fetcher = DelayedCountingFetcher(
            data: validImageData,
            delay: .milliseconds(50)
        )
        let cache = makeCache(dir: dir, fetcher: fetcher)

        async let first = cache.image(for: testURL)
        async let second = cache.image(for: testURL)
        async let third = cache.image(for: testURL)
        async let fourth = cache.image(for: testURL)
        let images = await [first, second, third, fourth]

        #expect(images.allSatisfy { $0 != nil })
        let callCount = await fetcher.calls()
        #expect(callCount == 1)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(files.count == 1)
    }

    @Test("cancelling one waiter returns promptly without cancelling shared work")
    func cancellingOneWaiterKeepsSharedPipelineAlive() async throws {
        let dir = try makeTempDir()
        let fetcher = ControlledArtworkFetcher()
        let cache = makeCache(dir: dir, fetcher: fetcher)
        let cancellationProbe = CompletionProbe()

        let first = Task { await cache.image(for: testURL) }
        #expect(await eventually { await fetcher.calls() == 1 })
        let cancelled = Task {
            let result = await cache.image(for: testURL)
            await cancellationProbe.markCompleted()
            return result
        }
        #expect(await eventually { await cache.inFlightWaiterCount(for: testURL) == 2 })

        cancelled.cancel()
        #expect(await eventually { await cancellationProbe.isCompleted() })
        #expect(await fetcher.calls() == 1)

        await fetcher.complete(with: validImageData)
        #expect(await cancelled.value == nil)
        #expect(await first.value != nil)
        #expect(await fetcher.calls() == 1)
    }

    @Test("clearing memory invalidates an uncooperative in-flight fetch")
    func clearMemoryPreventsStaleCommit() async throws {
        let dir = try makeTempDir()
        let fetcher = ControlledArtworkFetcher()
        let cache = makeCache(dir: dir, fetcher: fetcher)

        let load = Task { await cache.image(for: testURL) }
        #expect(await eventually { await fetcher.calls() == 1 })
        await cache.clearMemoryCache()
        #expect(await load.value == nil)

        // The fetcher intentionally ignores task cancellation. Its late response must not
        // repopulate memory after clearMemoryCache().
        await fetcher.complete(with: validImageData)
        #expect(await eventually { await fetcher.returns() == 1 })
        #expect(await eventually { await cache.completedLoadCount() == 1 })
        #expect(await cache.isStoredInMemory(testURL) == false)
    }

    @Test("memory LRU keeps a touched entry and evicts the true oldest")
    func memoryLRUEvictsTrueOldest() async throws {
        let dir = try makeTempDir()
        let fetcher = CountingFetcher(data: validImageData)
        let cache = makeCache(dir: dir, fetcher: fetcher, maxMemoryEntries: 2)
        let secondURL = URL(string: "https://example.com/second.jpg")!
        let thirdURL = URL(string: "https://example.com/third.jpg")!

        _ = await cache.image(for: testURL)
        _ = await cache.image(for: secondURL)
        _ = await cache.image(for: testURL)
        _ = await cache.image(for: thirdURL)

        #expect(await cache.isStoredInMemory(testURL))
        #expect(await cache.isStoredInMemory(secondURL) == false)
        #expect(await cache.isStoredInMemory(thirdURL))
    }

    // MARK: Disk cache

    @Test("disk hit within TTL skips network fetch and populates memory")
    func diskHitSkipsNetwork() async throws {
        let dir = try makeTempDir()

        // Warm disk via first cache instance
        let fetcher1 = CountingFetcher(data: validImageData)
        let cache1 = makeCache(dir: dir, fetcher: fetcher1)
        _ = await cache1.image(for: testURL)
        #expect(fetcher1.callCount == 1)

        // New instance = fresh memory cache, same dir, failing fetcher
        let fetcher2 = CountingFetcher(throwing: URLError(.timedOut))
        let cache2 = makeCache(dir: dir, fetcher: fetcher2)
        let result = await cache2.image(for: testURL)

        #expect(result != nil)
        #expect(fetcher2.callCount == 0)
    }

    @Test("expired disk entry triggers re-fetch and re-writes disk")
    func expiredDiskEntryRefetches() async throws {
        let dir = try makeTempDir()

        // Warm disk
        let fetcher1 = CountingFetcher(data: validImageData)
        let cache1 = makeCache(dir: dir, fetcher: fetcher1)
        _ = await cache1.image(for: testURL)

        // New instance with TTL=0 (all disk entries immediately expired)
        let fetcher2 = CountingFetcher(data: validImageData)
        let cache2 = makeCache(dir: dir, fetcher: fetcher2, ttl: 0)
        _ = await cache2.image(for: testURL)

        #expect(fetcher2.callCount == 1)
    }

    // MARK: Fetch failure

    @Test("fetch failure returns nil and writes nothing to disk")
    func fetchFailureReturnsNilWritesNothing() async throws {
        let dir = try makeTempDir()
        let fetcher = CountingFetcher(throwing: URLError(.badServerResponse))
        let cache = makeCache(dir: dir, fetcher: fetcher)

        let result = await cache.image(for: testURL)

        #expect(result == nil)

        // No file written in cache dir
        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(contents.isEmpty)
    }

    // MARK: Garbage collection — TTL

    @Test("GC removes expired files and keeps files within TTL")
    func gcRemovesExpiredKeepsValid() async throws {
        let dir = try makeTempDir()
        let fm = FileManager.default

        let valid1 = dir.appendingPathComponent("valid1.jpg")
        let valid2 = dir.appendingPathComponent("valid2.jpg")
        let expired = dir.appendingPathComponent("expired.jpg")

        try Data("img".utf8).write(to: valid1)
        try Data("img".utf8).write(to: valid2)
        try Data("img".utf8).write(to: expired)

        // Backdate the expired file to 100 days ago
        let oldDate = Date(timeIntervalSinceNow: -100 * 24 * 3600)
        try fm.setAttributes([.modificationDate: oldDate], ofItemAtPath: expired.path)

        let cache = makeCache(dir: dir, ttl: 90 * 24 * 3600)
        await cache.runGarbageCollection()

        #expect(fm.fileExists(atPath: valid1.path))
        #expect(fm.fileExists(atPath: valid2.path))
        #expect(!fm.fileExists(atPath: expired.path))
    }

    // MARK: Garbage collection — size cap

    @Test("GC size cap removes oldest files until total is under limit")
    func gcSizeCapRemovesOldest() async throws {
        let dir = try makeTempDir()
        let fm = FileManager.default

        // 5 files × 30 bytes = 150 bytes total; size cap = 100 bytes
        // After TTL phase (no files are expired), size cap must remove oldest 2:
        //   150 → remove file1 (30B) → 120 → remove file2 (30B) → 90 ≤ 100 → stop
        for i in 1...5 {
            let fileURL = dir.appendingPathComponent("file\(i).jpg")
            try Data(repeating: UInt8(i), count: 30).write(to: fileURL)
            // Space files 1 hour apart; file1 is oldest, file5 is newest
            let date = Date(timeIntervalSinceNow: TimeInterval(i - 6) * 3600)
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: fileURL.path)
        }

        let cache = makeCache(dir: dir, ttl: 90 * 24 * 3600, maxSizeBytes: 100)
        await cache.runGarbageCollection()

        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("file1.jpg").path))
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("file2.jpg").path))
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("file3.jpg").path))
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("file4.jpg").path))
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("file5.jpg").path))
    }
}
