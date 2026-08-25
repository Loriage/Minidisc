import Foundation
import ImageIO
import OSLog
import UIKit

// MARK: - ArtworkTier

/// Named decode resolution tier for cover art.
///
/// Tier determines both the pixel dimension passed to CGImageSourceCreateThumbnailAtIndex
/// and the disk/RAM cache key suffix (`id@thumb`, `id@hero`).
nonisolated enum ArtworkTier: String, Sendable {
    /// 240 px — list rows, grid cells, queue rows, mini player, Wrapped cards.
    case thumb
    /// 1200 px — detail view heroes, full-player cover, lock screen artwork.
    case hero

    var decodePixels: Int {
        switch self {
        case .thumb: return 240
        case .hero: return 1200
        }
    }
}

// MARK: - CoverFetchGate

/// Limits concurrent server cover fetches so they cannot saturate the TCP connection pool
/// shared with the active audio stream. Uses a continuation-based semaphore so callers
/// are suspended (not blocked) while waiting for a slot.
actor CoverFetchGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let limit: Int
    private var available: Int
    private var waiters: [Waiter] = []

    init(limit: Int) {
        precondition(limit > 0)
        self.limit = limit
        available = limit
    }

    func acquire() async throws {
        try Task.checkCancellation()
        if available > 0 {
            available -= 1
            if Task.isCancelled {
                available += 1
                throw CancellationError()
            }
            return
        }

        let waiterID = UUID()
        Logger.artworkCache.debug("[NET-COVER] gate: queued (limit=\(self.limit) busy, waiters=\(self.waiters.count + 1))")
        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters.append(Waiter(id: waiterID, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID) }
        }

        guard acquired else { throw CancellationError() }
        if Task.isCancelled {
            release()
            throw CancellationError()
        }
    }

    func release() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.continuation.resume(returning: true)
        } else {
            available = min(limit, available + 1)
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }

    /// Test seam for verifying that cancellation returns capacity to the gate.
    func availablePermitCount() -> Int {
        available
    }

    /// Test seam for observing registration before cancelling a queued waiter.
    func waitingCount() -> Int {
        waiters.count
    }
}

private extension CoverFetchGate {
    func acquireOrCancel() async -> Bool {
        do {
            try await acquire()
            return true
        } catch is CancellationError {
            return false
        } catch {
            return false
        }
    }
}

// MARK: - ArtworkImageCache

/// Two-tier LRU cover cache resolved from RAM, disk, then the server.
/// Legacy untagged files are skipped because decoding them can starve audio.
@MainActor
@Observable
final class ArtworkImageCache {
    private struct InFlightLoad {
        let id: UUID
        let epoch: UInt64
        let coverGeneration: UInt64
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<PlatformImage?, Never>]
    }

    private struct RevalidationEntry {
        let id: UUID
        let epoch: UInt64
        var coverGeneration: UInt64
        let task: Task<Void, Never>
    }

    private struct ServerArtwork: Sendable {
        let image: PlatformImage
        let data: Data
        let lastModified: String?
    }

    private struct DiskAccessWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    typealias CoverArtURLProvider = @Sendable (String, Int) async -> URL?
    typealias LocalCoverURLProvider = @Sendable (String) async -> URL?
    typealias PersistCoverOperation = @Sendable (Data, String) async -> Void
    typealias RemoveCoverOperation = @Sendable (String) async -> Void
    typealias HTTPDataLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    typealias ImageDecoder = @Sendable (Data, Int) async -> PlatformImage?

    /// Mirrors `CacheSettings.cacheArtwork`: when false, fetched covers stay memory-only and are not
    /// written to the persisted cover store. Set by AppContainer at launch and by the Settings toggle.
    var persistCoversEnabled = true

    private var cache: [String: PlatformImage] = [:]
    private var accessOrder: [String] = []
    private let maxEntries = 110

    private let coverArtURLProvider: CoverArtURLProvider
    private let localCoverURLProvider: LocalCoverURLProvider
    private let persistCoverOperation: PersistCoverOperation
    private let removeCoverOperation: RemoveCoverOperation
    private let dataLoader: HTTPDataLoader
    private let imageDecoder: ImageDecoder
    private let fetchGate = CoverFetchGate(limit: 4)
    private let decodeGate = CoverFetchGate(limit: 3)

    // MARK: - Revalidation
    /// Per-cover `Last-Modified` + last-checked, so a cached cover is re-verified on a slow cadence.
    private let revalidationStore: CoverRevalidationStore
    /// Cover ids whose revalidation is in flight, so the two tiers of one id don't both HEAD it.
    /// Loads currently running, keyed like `cache`, so concurrent callers for the same cover share
    /// one fetch + decode instead of racing each other.
    private var inFlight: [String: InFlightLoad] = [:]
    private var revalidating: [String: RevalidationEntry] = [:]
    /// Invalidates every older operation on a whole-cache clear.
    private var cacheEpoch: UInt64 = 0
    /// Invalidates older loads and revalidations for one logical cover across both tiers.
    private var coverGenerations: [String: UInt64] = [:]
    private var completedLoadCount = 0
    private var completedRevalidationCount = 0
    /// Per-cover disk mutation barrier. Reads, removes and persists are serialized, while network
    /// fetches stay outside the critical section. Generation checks connect those short critical
    /// sections into a transaction, so cancellation remains prompt and stale bytes cannot be
    /// persisted after a newer invalidation.
    private var diskAccessOwners: Set<String> = []
    private var diskAccessWaiters: [String: [DiskAccessWaiter]] = [:]
    /// Ids whose revalidation failed this run (offline / error). Skipped until relaunch so an
    /// offline session doesn't fire a HEAD per cover on every scroll.
    private var revalidationDeferred: Set<String> = []

    convenience init(
        downloadService: any DownloadServiceProtocol,
        libraryService: any ArtworkURLResolving,
        revalidationStore: CoverRevalidationStore = CoverRevalidationStore()
    ) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 30
        config.httpMaximumConnectionsPerHost = 2
        let session = URLSession(configuration: config)

        self.init(
            revalidationStore: revalidationStore,
            coverArtURLProvider: { id, size in
                await libraryService.coverArtURL(id: id, size: size)
            },
            localCoverURLProvider: { id in
                await downloadService.localCoverArtURL(forId: id)
            },
            persistCoverOperation: { data, id in
                await downloadService.persistCover(data, forId: id)
            },
            removeCoverOperation: { id in
                await downloadService.removeCover(forId: id)
            },
            dataLoader: { request in
                try await session.data(for: request)
            },
            imageDecoder: { data, maxDimension in
                await Task.detached(priority: .utility) {
                    ArtworkImageCache.thumbnailImage(
                        from: data,
                        maxDimension: maxDimension
                    )
                }.value
            }
        )
    }

    /// Dependency-injected initializer used by deterministic concurrency tests.
    init(
        revalidationStore: CoverRevalidationStore = CoverRevalidationStore(),
        coverArtURLProvider: @escaping CoverArtURLProvider,
        localCoverURLProvider: @escaping LocalCoverURLProvider = { _ in nil },
        persistCoverOperation: @escaping PersistCoverOperation = { _, _ in },
        removeCoverOperation: @escaping RemoveCoverOperation = { _ in },
        dataLoader: @escaping HTTPDataLoader,
        imageDecoder: @escaping ImageDecoder
    ) {
        self.revalidationStore = revalidationStore
        self.coverArtURLProvider = coverArtURLProvider
        self.localCoverURLProvider = localCoverURLProvider
        self.persistCoverOperation = persistCoverOperation
        self.removeCoverOperation = removeCoverOperation
        self.dataLoader = dataLoader
        self.imageDecoder = imageDecoder
    }

    // MARK: - Public API

    /// Returns the cached image for the given tier synchronously, or nil if not yet loaded.
    /// Does not trigger a fetch — call load(coverArtId:tier:) for that.
    func cached(for coverArtId: String?, tier: ArtworkTier = .thumb) -> PlatformImage? {
        guard let coverArtId else { return nil }
        let key = cacheKey(id: coverArtId, tier: tier)
        guard let image = cache[key] else { return nil }
        touch(key)
        return image
    }

    /// Read-only sync lookup — no LRU touch, no fetch.
    func cachedImage(for id: String, tier: ArtworkTier = .thumb) -> PlatformImage? {
        cache[cacheKey(id: id, tier: tier)]
    }

    /// Deterministic concurrency-test seam.
    func inFlightWaiterCount(for id: String, tier: ArtworkTier = .thumb) -> Int {
        inFlight[cacheKey(id: id, tier: tier)]?.waiters.count ?? 0
    }

    /// Deterministic revalidation-test seam.
    func isRevalidating(_ id: String) -> Bool {
        revalidating[id] != nil
    }

    func completedLoads() -> Int {
        completedLoadCount
    }

    func completedRevalidations() -> Int {
        completedRevalidationCount
    }

    /// Returns the image from cache if available; otherwise fetches from disk or server.
    /// The `tier` determines both decode resolution and which disk/RAM bucket is checked.
    @discardableResult
    func load(coverArtId: String?, tier: ArtworkTier = .thumb) async -> PlatformImage? {
        guard !Task.isCancelled, let coverArtId else { return nil }

        let key = cacheKey(id: coverArtId, tier: tier)

        if let hit = cache[key] {
            touch(key)
            revalidateIfDue(coverArtId: coverArtId, tier: tier)
            return hit
        }

        // Deduplicate concurrent loads for the same tier key.
        let waiterID = UUID()
        if let existing = inFlight[key] {
            return await waitForInFlightLoad(
                key: key,
                loadID: existing.id,
                waiterID: waiterID
            )
        }

        let loadID = UUID()
        let epoch = cacheEpoch
        let generation = coverGeneration(for: coverArtId)
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.fetch(
                coverArtId: coverArtId,
                tier: tier,
                key: key,
                loadID: loadID,
                epoch: epoch,
                coverGeneration: generation
            )
            self.completeInFlightLoad(
                key: key,
                loadID: loadID,
                epoch: epoch,
                coverGeneration: generation,
                result: result
            )
        }
        inFlight[key] = InFlightLoad(
            id: loadID,
            epoch: epoch,
            coverGeneration: generation,
            task: task,
            waiters: [:]
        )
        return await waitForInFlightLoad(
            key: key,
            loadID: loadID,
            waiterID: waiterID
        )
    }

    private func waitForInFlightLoad(
        key: String,
        loadID: UUID,
        waiterID: UUID
    ) async -> PlatformImage? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard var entry = inFlight[key], entry.id == loadID else {
                    continuation.resume(returning: Task.isCancelled ? nil : cache[key])
                    return
                }
                entry.waiters[waiterID] = continuation
                inFlight[key] = entry
                if Task.isCancelled {
                    cancelInFlightWaiter(key: key, loadID: loadID, waiterID: waiterID)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelInFlightWaiter(key: key, loadID: loadID, waiterID: waiterID)
            }
        }
    }

    private func cancelInFlightWaiter(key: String, loadID: UUID, waiterID: UUID) {
        guard var entry = inFlight[key], entry.id == loadID else { return }
        guard let continuation = entry.waiters.removeValue(forKey: waiterID) else { return }
        continuation.resume(returning: nil)
        guard entry.waiters.isEmpty else {
            inFlight[key] = entry
            return
        }
        inFlight.removeValue(forKey: key)
        entry.task.cancel()
    }

    private func completeInFlightLoad(
        key: String,
        loadID: UUID,
        epoch: UInt64,
        coverGeneration: UInt64,
        result: PlatformImage?
    ) {
        completedLoadCount += 1
        guard let entry = inFlight[key], entry.id == loadID else { return }
        inFlight.removeValue(forKey: key)
        let resolvedResult = entry.epoch == epoch
            && entry.coverGeneration == coverGeneration
            && cacheEpoch == epoch
            ? result
            : nil
        entry.waiters.values.forEach { $0.resume(returning: resolvedResult) }
    }

    /// Disk then network, for a key that missed RAM and has no load already in flight.
    private func fetch(
        coverArtId: String,
        tier: ArtworkTier,
        key: String,
        loadID: UUID,
        epoch: UInt64,
        coverGeneration: UInt64
    ) async -> PlatformImage? {
        let maxDim = tier.decodePixels
        guard canCommitLoad(
            key: key,
            loadID: loadID,
            coverArtId: coverArtId,
            epoch: epoch,
            coverGeneration: coverGeneration
        ) else { return nil }

        let tieredDiskId = "\(coverArtId)@\(tier.rawValue)"
        do {
            guard await acquireDiskAccess(for: coverArtId) else { return nil }
            defer { releaseDiskAccess(for: coverArtId) }
            guard canCommitLoad(
                key: key,
                loadID: loadID,
                coverArtId: coverArtId,
                epoch: epoch,
                coverGeneration: coverGeneration
            ) else { return nil }
            if let localURL = await localCoverURLProvider(tieredDiskId) {
                guard canCommitLoad(
                    key: key,
                    loadID: loadID,
                    coverArtId: coverArtId,
                    epoch: epoch,
                    coverGeneration: coverGeneration
                ) else { return nil }
                guard await decodeGate.acquireOrCancel() else { return nil }
                let image = await Task.detached(priority: .utility) {
                    let diskStart = CFAbsoluteTimeGetCurrent()
                    guard let data = try? Data(contentsOf: localURL) else { return nil as PlatformImage? }
                    let diskMs = Int((CFAbsoluteTimeGetCurrent() - diskStart) * 1000)
                    let decodeStart = CFAbsoluteTimeGetCurrent()
                    let image = ArtworkImageCache.thumbnailImage(from: data, maxDimension: maxDim)
                    let decodeMs = Int((CFAbsoluteTimeGetCurrent() - decodeStart) * 1000)
                    if diskMs + decodeMs > 50 {
                        Logger.artworkCache.warning("[DISK-SLOW] id=\(coverArtId, privacy: .public) tier=\(tier.rawValue, privacy: .public) disk=\(diskMs)ms decode=\(decodeMs)ms (background thread)")
                    } else {
                        Logger.artworkCache.debug("[DISK] id=\(coverArtId, privacy: .public) tier=\(tier.rawValue, privacy: .public) disk=\(diskMs)ms decode=\(decodeMs)ms")
                    }
                    return image
                }.value
                await decodeGate.release()
                guard canCommitLoad(
                    key: key,
                    loadID: loadID,
                    coverArtId: coverArtId,
                    epoch: epoch,
                    coverGeneration: coverGeneration
                ) else { return nil }
                if let image {
                    store(image: image, forKey: key)
                    Logger.artworkCache.debug("ArtworkImageCache: disk hit \(coverArtId, privacy: .public) tier=\(tier.rawValue, privacy: .public) (\(self.cache.count, privacy: .public)/\(self.maxEntries, privacy: .public))")
                    revalidateIfDue(coverArtId: coverArtId, tier: tier)
                    return image
                }
            }
        }

        guard await fetchGate.acquireOrCancel() else { return nil }
        Logger.artworkCache.debug("[NET-COVER] start id=\(coverArtId, privacy: .public) tier=\(tier.rawValue, privacy: .public) size=\(maxDim)px")
        let serverArtwork = await fetchServerArtwork(coverArtId: coverArtId, tier: tier)
        await fetchGate.release()
        guard let serverArtwork,
              canCommitLoad(
                  key: key,
                  loadID: loadID,
                  coverArtId: coverArtId,
                  epoch: epoch,
                  coverGeneration: coverGeneration
              ) else { return nil }

        if persistCoversEnabled {
            guard await acquireDiskAccess(for: coverArtId) else { return nil }
            defer { releaseDiskAccess(for: coverArtId) }
            guard canCommitLoad(
                key: key,
                loadID: loadID,
                coverArtId: coverArtId,
                epoch: epoch,
                coverGeneration: coverGeneration
            ) else { return nil }
            await persistCoverOperation(serverArtwork.data, tieredDiskId)
            guard canCommitLoad(
                key: key,
                loadID: loadID,
                coverArtId: coverArtId,
                epoch: epoch,
                coverGeneration: coverGeneration
            ) else { return nil }
        }

        store(image: serverArtwork.image, forKey: key)
        revalidationStore.record(id: coverArtId, lastModified: serverArtwork.lastModified)
        return serverArtwork.image
    }

    private func fetchServerArtwork(coverArtId: String, tier: ArtworkTier) async -> ServerArtwork? {
        let maxDim = tier.decodePixels
        guard !Task.isCancelled,
              let serverURL = await coverArtURLProvider(coverArtId, maxDim),
              !Task.isCancelled else { return nil }
        let t0 = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await dataLoader(URLRequest(url: serverURL))
        } catch is CancellationError {
            return nil
        } catch {
            guard !Task.isCancelled else { return nil }
            Logger.artworkCache.warning("[NET-COVER] failed id=\(coverArtId, privacy: .public) duration=\(Int(Date().timeIntervalSince(t0) * 1000))ms")
            return nil
        }
        guard !Task.isCancelled else { return nil }
        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            Logger.artworkCache.warning("[NET-COVER] failed status=\(http.statusCode) id=\(coverArtId, privacy: .public)")
            return nil
        }
        let image = await imageDecoder(data, maxDim)
        guard !Task.isCancelled, let image else {
            Logger.artworkCache.warning("[NET-COVER] failed (decode) id=\(coverArtId, privacy: .public) duration=\(Int(Date().timeIntervalSince(t0) * 1000))ms")
            return nil
        }
        Logger.artworkCache.debug("[NET-COVER] done id=\(coverArtId, privacy: .public) tier=\(tier.rawValue, privacy: .public) duration=\(Int(Date().timeIntervalSince(t0) * 1000))ms bytes=\(data.count, privacy: .public)")
        let lastModified = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Last-Modified")
        return ServerArtwork(image: image, data: data, lastModified: lastModified)
    }

    // MARK: - Revalidation

    /// Fires a background re-check of `coverArtId` when its TTL has lapsed. Non-blocking: the caller
    /// has already returned the cached image, so this is pure stale-while-revalidate — the view
    /// keeps the old cover until (and unless) a change is found.
    private func revalidateIfDue(coverArtId: String, tier: ArtworkTier) {
        guard revalidating[coverArtId] == nil,
              !revalidationDeferred.contains(coverArtId),
              revalidationStore.isDue(id: coverArtId) else { return }

        let revalidationID = UUID()
        let epoch = cacheEpoch
        let generation = coverGeneration(for: coverArtId)
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.revalidate(
                coverArtId: coverArtId,
                tier: tier,
                revalidationID: revalidationID,
                epoch: epoch,
                coverGeneration: generation
            )
            self.finishRevalidation(coverArtId: coverArtId, revalidationID: revalidationID)
        }
        revalidating[coverArtId] = RevalidationEntry(
            id: revalidationID,
            epoch: epoch,
            coverGeneration: generation,
            task: task
        )
    }

    private func revalidate(
        coverArtId: String,
        tier: ArtworkTier,
        revalidationID: UUID,
        epoch: UInt64,
        coverGeneration: UInt64
    ) async {
        guard isCurrentRevalidation(
            coverArtId: coverArtId,
            revalidationID: revalidationID,
            epoch: epoch,
            coverGeneration: coverGeneration
        ), let url = await coverArtURLProvider(coverArtId, tier.decodePixels),
           isCurrentRevalidation(
               coverArtId: coverArtId,
               revalidationID: revalidationID,
               epoch: epoch,
               coverGeneration: coverGeneration
           ) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let response: URLResponse
        do {
            (_, response) = try await dataLoader(request)
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentRevalidation(
                coverArtId: coverArtId,
                revalidationID: revalidationID,
                epoch: epoch,
                coverGeneration: coverGeneration
            ) else { return }
            // Avoid a HEAD request per row while offline.
            revalidationDeferred.insert(coverArtId)
            return
        }
        guard isCurrentRevalidation(
            coverArtId: coverArtId,
            revalidationID: revalidationID,
            epoch: epoch,
            coverGeneration: coverGeneration
        ) else { return }
        guard let http = response as? HTTPURLResponse else {
            revalidationDeferred.insert(coverArtId)
            return
        }

        let serverLM = http.value(forHTTPHeaderField: "Last-Modified")
        switch CoverRevalidationOutcome.decide(stored: revalidationStore.lastModified(for: coverArtId), server: serverLM) {
        case .baseline, .unchanged, .indeterminate:
            revalidationStore.record(id: coverArtId, lastModified: serverLM)
        case .changed:
            Logger.artworkCache.info("[REVAL] cover changed id=\(coverArtId, privacy: .public) — refetching")
            await refetchChangedCover(
                coverArtId: coverArtId,
                tier: tier,
                newLastModified: serverLM,
                revalidationID: revalidationID,
                epoch: epoch,
                previousCoverGeneration: coverGeneration
            )
        }
    }

    /// Replaces every cached copy of a cover that changed on the server, then nudges the UI to
    /// re-read it. The tier that triggered the check is fetched now; the other tier is dropped so it
    /// re-fetches fresh on its next access.
    private func refetchChangedCover(
        coverArtId: String,
        tier: ArtworkTier,
        newLastModified: String?,
        revalidationID: UUID,
        epoch: UInt64,
        previousCoverGeneration: UInt64
    ) async {
        guard let generation = beginChangedRevalidation(
            coverArtId: coverArtId,
            revalidationID: revalidationID,
            epoch: epoch,
            previousCoverGeneration: previousCoverGeneration
        ) else { return }

        let tieredKeys = [ArtworkTier.thumb, .hero].map {
            cacheKey(id: coverArtId, tier: $0)
        }
        for staleKey in tieredKeys {
            cache.removeValue(forKey: staleKey)
            accessOrder.removeAll { $0 == staleKey }
        }

        do {
            guard await acquireDiskAccess(for: coverArtId) else { return }
            defer { releaseDiskAccess(for: coverArtId) }
            guard isCurrentRevalidation(
                coverArtId: coverArtId,
                revalidationID: revalidationID,
                epoch: epoch,
                coverGeneration: generation
            ) else { return }
            for staleKey in tieredKeys + [coverArtId] {
                await removeCoverOperation(staleKey)
                guard isCurrentRevalidation(
                    coverArtId: coverArtId,
                    revalidationID: revalidationID,
                    epoch: epoch,
                    coverGeneration: generation
                ) else { return }
            }
        }

        guard await fetchGate.acquireOrCancel() else { return }
        let refreshedArtwork = await fetchServerArtwork(coverArtId: coverArtId, tier: tier)
        await fetchGate.release()
        guard let refreshedArtwork,
              isCurrentRevalidation(
                  coverArtId: coverArtId,
                  revalidationID: revalidationID,
                  epoch: epoch,
                  coverGeneration: generation
              ) else { return }

        let key = cacheKey(id: coverArtId, tier: tier)
        if persistCoversEnabled {
            guard await acquireDiskAccess(for: coverArtId) else { return }
            defer { releaseDiskAccess(for: coverArtId) }
            guard isCurrentRevalidation(
                coverArtId: coverArtId,
                revalidationID: revalidationID,
                epoch: epoch,
                coverGeneration: generation
            ) else { return }
            await persistCoverOperation(refreshedArtwork.data, key)
            guard isCurrentRevalidation(
                coverArtId: coverArtId,
                revalidationID: revalidationID,
                epoch: epoch,
                coverGeneration: generation
            ) else { return }
        }

        store(image: refreshedArtwork.image, forKey: key)
        revalidationStore.record(
            id: coverArtId,
            lastModified: refreshedArtwork.lastModified ?? newLastModified
        )
        let versionKey = "coverArtUploadVersion"
        UserDefaults.standard.set(
            UserDefaults.standard.integer(forKey: versionKey) + 1,
            forKey: versionKey
        )
    }

    func invalidate(for coverArtId: String) async {
        _ = bumpCoverGeneration(for: coverArtId)
        cancelRevalidation(for: coverArtId)
        revalidationDeferred.remove(coverArtId)
        revalidationStore.remove(id: coverArtId)

        let keys = ["\(coverArtId)@thumb", "\(coverArtId)@hero", coverArtId]
        for key in keys {
            cancelInFlightLoad(forKey: key)
            cache.removeValue(forKey: key)
            accessOrder.removeAll { $0 == key }
        }
        // Invalidation is a consistency boundary rather than a best-effort read. Once the
        // generation has been bumped, finish removing every tier even if the initiating UI task is
        // cancelled; otherwise a later load could resurrect the explicitly invalidated bytes.
        _ = await acquireDiskAccess(for: coverArtId, respectsCancellation: false)
        defer { releaseDiskAccess(for: coverArtId) }
        for key in keys {
            await removeCoverOperation(key)
        }
        Logger.artworkCache.debug("ArtworkImageCache: invalidated \(coverArtId, privacy: .public) (RAM + disk)")
    }

    func clearCache() {
        cacheEpoch &+= 1
        let loads = inFlight.values
        inFlight.removeAll()
        loads.forEach { entry in
            entry.task.cancel()
            entry.waiters.values.forEach { $0.resume(returning: nil) }
        }
        revalidating.values.forEach { $0.task.cancel() }
        revalidating.removeAll()
        cache.removeAll()
        accessOrder.removeAll()
    }

    /// Forgets all revalidation metadata. Called from the version-bump disk wipe so a fresh cache
    /// doesn't carry `Last-Modified` values describing images that were just deleted.
    func clearRevalidationMetadata() {
        revalidating.values.forEach { $0.task.cancel() }
        revalidating.removeAll()
        revalidationStore.removeAll()
        revalidationDeferred.removeAll()
    }

    // MARK: - Private

    private func acquireDiskAccess(
        for coverArtId: String,
        respectsCancellation: Bool = true
    ) async -> Bool {
        if respectsCancellation, Task.isCancelled { return false }
        if diskAccessOwners.insert(coverArtId).inserted {
            return true
        }

        let waiterID = UUID()
        let acquired: Bool
        if respectsCancellation {
            acquired = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if Task.isCancelled {
                        continuation.resume(returning: false)
                    } else {
                        diskAccessWaiters[coverArtId, default: []].append(
                            DiskAccessWaiter(id: waiterID, continuation: continuation)
                        )
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.cancelDiskAccessWaiter(for: coverArtId, id: waiterID)
                }
            }
        } else {
            acquired = await withCheckedContinuation { continuation in
                diskAccessWaiters[coverArtId, default: []].append(
                    DiskAccessWaiter(id: waiterID, continuation: continuation)
                )
            }
        }

        if respectsCancellation, acquired, Task.isCancelled {
            releaseDiskAccess(for: coverArtId)
            return false
        }
        return acquired
    }

    private func cancelDiskAccessWaiter(for coverArtId: String, id: UUID) {
        guard var waiters = diskAccessWaiters[coverArtId],
              let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        if waiters.isEmpty {
            diskAccessWaiters.removeValue(forKey: coverArtId)
        } else {
            diskAccessWaiters[coverArtId] = waiters
        }
        waiter.continuation.resume(returning: false)
    }

    private func releaseDiskAccess(for coverArtId: String) {
        guard diskAccessOwners.remove(coverArtId) != nil else {
            assertionFailure("Released unowned artwork disk barrier for \(coverArtId)")
            return
        }
        guard var waiters = diskAccessWaiters[coverArtId], !waiters.isEmpty else {
            diskAccessWaiters.removeValue(forKey: coverArtId)
            return
        }
        let waiter = waiters.removeFirst()
        if waiters.isEmpty {
            diskAccessWaiters.removeValue(forKey: coverArtId)
        } else {
            diskAccessWaiters[coverArtId] = waiters
        }
        diskAccessOwners.insert(coverArtId)
        waiter.continuation.resume(returning: true)
    }

    private func cacheKey(id: String, tier: ArtworkTier) -> String {
        "\(id)@\(tier.rawValue)"
    }

    private func coverGeneration(for coverArtId: String) -> UInt64 {
        coverGenerations[coverArtId, default: 0]
    }

    @discardableResult
    private func bumpCoverGeneration(for coverArtId: String) -> UInt64 {
        let generation = coverGeneration(for: coverArtId) &+ 1
        coverGenerations[coverArtId] = generation
        return generation
    }

    private func canCommitLoad(
        key: String,
        loadID: UUID,
        coverArtId: String,
        epoch: UInt64,
        coverGeneration: UInt64
    ) -> Bool {
        guard !Task.isCancelled,
              cacheEpoch == epoch,
              self.coverGeneration(for: coverArtId) == coverGeneration,
              let entry = inFlight[key] else { return false }
        return entry.id == loadID
            && entry.epoch == epoch
            && entry.coverGeneration == coverGeneration
    }

    private func cancelInFlightLoad(forKey key: String) {
        guard let entry = inFlight.removeValue(forKey: key) else { return }
        entry.task.cancel()
        entry.waiters.values.forEach { $0.resume(returning: nil) }
    }

    private func cancelRevalidation(for coverArtId: String) {
        revalidating.removeValue(forKey: coverArtId)?.task.cancel()
    }

    private func isCurrentRevalidation(
        coverArtId: String,
        revalidationID: UUID,
        epoch: UInt64,
        coverGeneration: UInt64
    ) -> Bool {
        guard !Task.isCancelled,
              cacheEpoch == epoch,
              self.coverGeneration(for: coverArtId) == coverGeneration,
              let entry = revalidating[coverArtId] else { return false }
        return entry.id == revalidationID
            && entry.epoch == epoch
            && entry.coverGeneration == coverGeneration
    }

    private func beginChangedRevalidation(
        coverArtId: String,
        revalidationID: UUID,
        epoch: UInt64,
        previousCoverGeneration: UInt64
    ) -> UInt64? {
        guard isCurrentRevalidation(
            coverArtId: coverArtId,
            revalidationID: revalidationID,
            epoch: epoch,
            coverGeneration: previousCoverGeneration
        ), var entry = revalidating[coverArtId] else { return nil }

        let generation = bumpCoverGeneration(for: coverArtId)
        entry.coverGeneration = generation
        revalidating[coverArtId] = entry
        for tier in [ArtworkTier.thumb, .hero] {
            cancelInFlightLoad(forKey: cacheKey(id: coverArtId, tier: tier))
        }
        return generation
    }

    private func finishRevalidation(coverArtId: String, revalidationID: UUID) {
        completedRevalidationCount += 1
        guard revalidating[coverArtId]?.id == revalidationID else { return }
        revalidating.removeValue(forKey: coverArtId)
    }

    private func store(image: PlatformImage, forKey key: String) {
        cache[key] = image
        touch(key)
        while cache.count > maxEntries, let oldest = accessOrder.first {
            cache.removeValue(forKey: oldest)
            accessOrder.removeFirst()
        }
    }

    private func touch(_ key: String) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }

    /// Decodes `data` using `CGImageSourceCreateThumbnailAtIndex`, which only reads the DCT
    /// data needed for the target resolution — dramatically faster than full decode for
    /// high-res covers. Falls back to `PlatformImage(data:)` if ImageIO cannot produce
    /// a thumbnail (e.g. unsupported format).
    ///
    /// `nonisolated` so it is callable from `Task.detached` without hopping to MainActor.
    /// Internal (not private) so `CoverArtView`'s local-base fallback decodes identically.
    nonisolated static func thumbnailImage(from data: Data, maxDimension: Int) -> PlatformImage? {
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return PlatformImage(data: data)
        }
        return UIImage(cgImage: cgImage)
    }
}
