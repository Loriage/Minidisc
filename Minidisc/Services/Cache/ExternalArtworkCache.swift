import Foundation
import CryptoKit
import OSLog
import UIKit

// MARK: - Fetcher protocol (testability seam)

nonisolated protocol ExternalArtworkFetcher: Sendable {
    func fetchData(from url: URL) async throws -> Data
}

struct URLSessionExternalFetcher: ExternalArtworkFetcher {
    private let session: URLSession

    nonisolated init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        session = URLSession(configuration: config)
    }

    nonisolated func fetchData(from url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

// MARK: - Cache actor

/// Disk + memory cache for external cover art (e.g. Cover Art Archive).
/// Resolution order: memory LRU → disk (Caches/app.minidisc/external-covers/) → network.
/// Disk entries expire after 90 days; GC enforces a 100 MB size cap on top of TTL.
actor ExternalArtworkCache {
    /// Serializes disk reads/writes with the full GC scan so GC cannot delete a file while an
    /// atomic replacement is being committed.
    private final class DiskCoordinator: @unchecked Sendable {
        private let lock = NSLock()

        func withLock<T>(_ operation: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return operation()
        }
    }

    private enum LoadSource: Sendable {
        case disk
        case network
        case corrupt
        case cancelled
        case failed(String)
    }

    private struct LoadResult: Sendable {
        let image: PlatformImage?
        let source: LoadSource
    }

    private struct InFlightEntry {
        let id: UUID
        let generation: UInt64
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<PlatformImage?, Never>]
    }

    private struct GarbageCollectionResult: Sendable {
        let expiredCount: Int
        let capRemovedCount: Int
    }

    // MARK: - Configuration

    private let ttl: TimeInterval
    private let maxSizeBytes: Int64
    private let maxMemoryEntries: Int

    // MARK: - Storage

    private let cacheDirectory: URL
    private let fetcher: any ExternalArtworkFetcher
    private let diskCoordinator = DiskCoordinator()

    // MARK: - Memory cache (LRU, keyed by URL)

    private var memoryCache: [URL: PlatformImage] = [:]
    private var accessOrder: [URL] = []
    /// One disk/network pipeline per URL. The task does no actor-isolated work; only the final LRU
    /// commit returns to this actor.
    private var inFlight: [URL: InFlightEntry] = [:]
    /// Incremented when memory is explicitly cleared so older pipelines cannot repopulate it.
    private var memoryGeneration: UInt64 = 0
    private var completedPipelineCount = 0

    // MARK: - Init

    init(
        cacheDirectory: URL? = nil,
        fetcher: (any ExternalArtworkFetcher)? = nil,
        ttl: TimeInterval = 90 * 24 * 3600,
        maxSizeBytes: Int64 = 100 * 1024 * 1024,
        maxMemoryEntries: Int = 30
    ) {
        let dir: URL
        if let cacheDirectory {
            dir = cacheDirectory
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            dir = caches.appendingPathComponent("app.minidisc/external-covers", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.cacheDirectory = dir
        self.fetcher = fetcher ?? URLSessionExternalFetcher()
        self.ttl = ttl
        self.maxSizeBytes = maxSizeBytes
        self.maxMemoryEntries = maxMemoryEntries
    }

    // MARK: - Public API

    func image(for url: URL) async -> PlatformImage? {
        guard !Task.isCancelled else { return nil }

        // 1. Memory hit
        if let hit = memoryCache[url] {
            touchMemory(url)
            Logger.externalArtwork.debug("ExternalArtworkCache: memory hit \(url.lastPathComponent, privacy: .public)")
            return hit
        }

        // 2. Share any disk/network pipeline already running for this URL.
        let waiterID = UUID()
        if let existing = inFlight[url] {
            return await waitForImage(
                url: url,
                requestID: existing.id,
                waiterID: waiterID
            )
        }

        // 3. Resolve disk then network outside the cache actor. File I/O and image decoding can take
        // hundreds of milliseconds for a cold cache and must not serialize unrelated memory hits.
        let fileURL = diskURL(for: url)
        let requestID = UUID()
        let ttl = self.ttl
        let cacheDirectory = self.cacheDirectory
        let fetcher = self.fetcher
        let diskCoordinator = self.diskCoordinator
        let generation = memoryGeneration
        let task = Task.detached(priority: .utility) { [weak self] in
            let result = await Self.loadImage(
                for: url,
                fileURL: fileURL,
                cacheDirectory: cacheDirectory,
                ttl: ttl,
                fetcher: fetcher,
                diskCoordinator: diskCoordinator
            )
            let wasCancelled = Task.isCancelled
            await self?.completeLoad(
                url: url,
                requestID: requestID,
                generation: generation,
                result: result,
                wasCancelled: wasCancelled
            )
        }
        inFlight[url] = InFlightEntry(
            id: requestID,
            generation: generation,
            task: task,
            waiters: [:]
        )

        return await waitForImage(
            url: url,
            requestID: requestID,
            waiterID: waiterID
        )
    }

    private func waitForImage(
        url: URL,
        requestID: UUID,
        waiterID: UUID
    ) async -> PlatformImage? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard var entry = inFlight[url], entry.id == requestID else {
                    continuation.resume(
                        returning: Task.isCancelled ? nil : memoryCache[url]
                    )
                    return
                }
                entry.waiters[waiterID] = continuation
                inFlight[url] = entry
                if Task.isCancelled {
                    cancelWaiter(url: url, requestID: requestID, waiterID: waiterID)
                }
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(
                    url: url,
                    requestID: requestID,
                    waiterID: waiterID
                )
            }
        }
    }

    private func cancelWaiter(url: URL, requestID: UUID, waiterID: UUID) {
        guard var entry = inFlight[url],
              entry.id == requestID,
              let continuation = entry.waiters.removeValue(forKey: waiterID) else { return }
        continuation.resume(returning: nil)
        guard entry.waiters.isEmpty else {
            inFlight[url] = entry
            return
        }
        inFlight.removeValue(forKey: url)
        entry.task.cancel()
    }

    private func completeLoad(
        url: URL,
        requestID: UUID,
        generation: UInt64,
        result: LoadResult,
        wasCancelled: Bool
    ) {
        completedPipelineCount += 1
        guard let entry = inFlight[url],
              entry.id == requestID,
              entry.generation == generation else { return }
        inFlight.removeValue(forKey: url)

        let canCommit = !wasCancelled && memoryGeneration == generation
        let image = canCommit ? result.image : nil
        if let image {
            storeMemory(image, for: url)
        }
        switch result.source {
        case .disk:
            Logger.externalArtwork.debug("ExternalArtworkCache: disk hit \(url.lastPathComponent, privacy: .public)")
        case .network:
            Logger.externalArtwork.debug("ExternalArtworkCache: fetched + cached \(url.lastPathComponent, privacy: .public)")
        case .corrupt:
            Logger.externalArtwork.warning("ExternalArtworkCache: corrupt data from \(url, privacy: .public)")
        case .failed(let message):
            Logger.externalArtwork.warning("ExternalArtworkCache: fetch failed for \(url, privacy: .public) — \(message, privacy: .public)")
        case .cancelled:
            break
        }
        entry.waiters.values.forEach { $0.resume(returning: image) }
    }

    func clearMemoryCache() {
        memoryGeneration &+= 1
        let entries = inFlight.values
        inFlight.removeAll()
        entries.forEach { entry in
            entry.task.cancel()
            entry.waiters.values.forEach { $0.resume(returning: nil) }
        }
        memoryCache.removeAll()
        accessOrder.removeAll()
    }

    /// Deterministic concurrency/LRU-test seams.
    func inFlightWaiterCount(for url: URL) -> Int {
        inFlight[url]?.waiters.count ?? 0
    }

    func isStoredInMemory(_ url: URL) -> Bool {
        memoryCache[url] != nil
    }

    func completedLoadCount() -> Int {
        completedPipelineCount
    }

    // MARK: - Garbage collection

    /// Purges expired files (modification date > TTL), then enforces the size cap
    /// by deleting the oldest surviving files until total is under maxSizeBytes.
    func runGarbageCollection() async {
        let cacheDirectory = self.cacheDirectory
        let ttl = self.ttl
        let maxSizeBytes = self.maxSizeBytes
        let diskCoordinator = self.diskCoordinator
        let result = await Task.detached(priority: .utility) {
            diskCoordinator.withLock {
                Self.performGarbageCollection(
                    cacheDirectory: cacheDirectory,
                    ttl: ttl,
                    maxSizeBytes: maxSizeBytes
                )
            }
        }.value
        Logger.externalArtwork.info(
            "ExternalArtworkCache: GC done — \(result.expiredCount) expired, \(result.capRemovedCount) over cap"
        )
    }

    private nonisolated static func performGarbageCollection(
        cacheDirectory: URL,
        ttl: TimeInterval,
        maxSizeBytes: Int64
    ) -> GarbageCollectionResult {
        let fm = FileManager.default
        let resourceKeys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        guard let contents = try? fm.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: Array(resourceKeys),
            options: .skipsHiddenFiles
        ) else {
            return GarbageCollectionResult(expiredCount: 0, capRemovedCount: 0)
        }

        let expiryDate = Date(timeIntervalSinceNow: -ttl)
        var survivors: [(url: URL, modDate: Date, size: Int64)] = []
        var expiredCount = 0

        // Phase 1: TTL purge
        for fileURL in contents {
            let values = try? fileURL.resourceValues(forKeys: resourceKeys)
            let modDate = values?.contentModificationDate ?? .distantPast
            let size = Int64(values?.fileSize ?? 0)

            if modDate < expiryDate {
                try? fm.removeItem(at: fileURL)
                expiredCount += 1
            } else {
                survivors.append((fileURL, modDate, size))
            }
        }

        // Phase 2: size cap — delete oldest first until total <= maxSizeBytes
        let totalSize = survivors.reduce(0) { $0 + $1.size }
        var capRemovedCount = 0
        if totalSize > maxSizeBytes {
            let sorted = survivors.sorted { $0.modDate < $1.modDate }
            var runningSize = totalSize
            for entry in sorted {
                guard runningSize > maxSizeBytes else { break }
                try? fm.removeItem(at: entry.url)
                runningSize -= entry.size
                capRemovedCount += 1
            }
        }

        return GarbageCollectionResult(
            expiredCount: expiredCount,
            capRemovedCount: capRemovedCount
        )
    }

    // MARK: - Private helpers

    private func diskURL(for url: URL) -> URL {
        cacheDirectory.appendingPathComponent(sha256(url.absoluteString) + ".jpg")
    }

    private nonisolated static func loadImage(
        for url: URL,
        fileURL: URL,
        cacheDirectory: URL,
        ttl: TimeInterval,
        fetcher: any ExternalArtworkFetcher,
        diskCoordinator: DiskCoordinator
    ) async -> LoadResult {
        if let image = diskCoordinator.withLock({
            diskImage(at: fileURL, ttl: ttl)
        }) {
            return LoadResult(image: image, source: .disk)
        }

        do {
            try Task.checkCancellation()
            let data = try await fetcher.fetchData(from: url)
            try Task.checkCancellation()
            guard let image = PlatformImage(data: data) else {
                return LoadResult(image: nil, source: .corrupt)
            }
            try Task.checkCancellation()
            diskCoordinator.withLock {
                guard !Task.isCancelled else { return }
                try? FileManager.default.createDirectory(
                    at: cacheDirectory,
                    withIntermediateDirectories: true
                )
                try? data.write(to: fileURL, options: .atomic)
            }
            try Task.checkCancellation()
            return LoadResult(image: image, source: .network)
        } catch is CancellationError {
            return LoadResult(image: nil, source: .cancelled)
        } catch {
            guard !Task.isCancelled else {
                return LoadResult(image: nil, source: .cancelled)
            }
            return LoadResult(image: nil, source: .failed(String(describing: error)))
        }
    }

    private nonisolated static func diskImage(at fileURL: URL, ttl: TimeInterval) -> PlatformImage? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let modDate = attrs?[.modificationDate] as? Date,
              Date().timeIntervalSince(modDate) < ttl,
              let data = try? Data(contentsOf: fileURL),
              let image = PlatformImage(data: data) else {
            return nil
        }
        return image
    }

    private func storeMemory(_ image: PlatformImage, for url: URL) {
        memoryCache[url] = image
        touchMemory(url)
        while memoryCache.count > maxMemoryEntries, let oldest = accessOrder.first {
            memoryCache.removeValue(forKey: oldest)
            accessOrder.removeFirst()
        }
    }

    private func touchMemory(_ url: URL) {
        accessOrder.removeAll { $0 == url }
        accessOrder.append(url)
    }

    private func sha256(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
