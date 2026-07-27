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
private actor CoverFetchGate {
    private let limit: Int
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit; available = limit }

    func acquire() async {
        if available > 0 { available -= 1; return }
        Logger.artworkCache.debug("[NET-COVER] gate: queued (limit=\(self.limit) busy, waiters=\(self.waiters.count + 1))")
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            available += 1
        }
    }
}

// MARK: - ArtworkImageCache

/// Two-tier LRU cover cache resolved from RAM, disk, then the server.
/// Legacy untagged files are skipped because decoding them can starve audio.
@MainActor
@Observable
final class ArtworkImageCache {
    /// Mirrors `CacheSettings.cacheArtwork`: when false, fetched covers stay memory-only and are not
    /// written to the persisted cover store. Set by AppContainer at launch and by the Settings toggle.
    var persistCoversEnabled = true

    private var cache: [String: PlatformImage] = [:]
    private var accessOrder: [String] = []
    private let maxEntries = 110

    private let downloadService: any DownloadServiceProtocol
    private let libraryService: any LibraryServiceProtocol
    private let session: URLSession
    private let fetchGate = CoverFetchGate(limit: 4)
    private let decodeGate = CoverFetchGate(limit: 3)

    // MARK: - Revalidation
    /// Per-cover `Last-Modified` + last-checked, so a cached cover is re-verified on a slow cadence.
    private let revalidationStore: CoverRevalidationStore
    /// Cover ids whose revalidation is in flight, so the two tiers of one id don't both HEAD it.
    /// Loads currently running, keyed like `cache`, so concurrent callers for the same cover share
    /// one fetch + decode instead of racing each other.
    private var inFlight: [String: Task<PlatformImage?, Never>] = [:]
    private var revalidating: Set<String> = []
    /// Ids whose revalidation failed this run (offline / error). Skipped until relaunch so an
    /// offline session doesn't fire a HEAD per cover on every scroll.
    private var revalidationDeferred: Set<String> = []

    init(
        downloadService: any DownloadServiceProtocol,
        libraryService: any LibraryServiceProtocol,
        revalidationStore: CoverRevalidationStore = CoverRevalidationStore()
    ) {
        self.downloadService = downloadService
        self.libraryService = libraryService
        self.revalidationStore = revalidationStore
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 30
        config.httpMaximumConnectionsPerHost = 2
        self.session = URLSession(configuration: config)
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

    /// Returns the image from cache if available; otherwise fetches from disk or server.
    /// The `tier` determines both decode resolution and which disk/RAM bucket is checked.
    @discardableResult
    func load(coverArtId: String?, tier: ArtworkTier = .thumb) async -> PlatformImage? {
        guard let coverArtId else { return nil }

        let key = cacheKey(id: coverArtId, tier: tier)

        if let hit = cache[key] {
            touch(key)
            revalidateIfDue(coverArtId: coverArtId, tier: tier)
            return hit
        }

        // Deduplicate concurrent loads for the same tier key.
        if let existing = inFlight[key] {
            return await existing.value
        }

        let task = Task { @MainActor in
            defer { self.inFlight[key] = nil }
            return await self.fetch(coverArtId: coverArtId, tier: tier, key: key)
        }
        inFlight[key] = task
        return await task.value
    }

    /// Disk then network, for a key that missed RAM and has no load already in flight.
    private func fetch(coverArtId: String, tier: ArtworkTier, key: String) async -> PlatformImage? {
        let maxDim = tier.decodePixels

        let tieredDiskId = "\(coverArtId)@\(tier.rawValue)"
        if let localURL = await downloadService.localCoverArtURL(forId: tieredDiskId) {
            await decodeGate.acquire()
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
            if let image {
                store(image: image, forKey: key)
                Logger.artworkCache.debug("ArtworkImageCache: disk hit \(coverArtId, privacy: .public) tier=\(tier.rawValue, privacy: .public) (\(self.cache.count, privacy: .public)/\(self.maxEntries, privacy: .public))")
                revalidateIfDue(coverArtId: coverArtId, tier: tier)
                return image
            }
        }

        await fetchGate.acquire()
        Logger.artworkCache.debug("[NET-COVER] start id=\(coverArtId, privacy: .public) tier=\(tier.rawValue, privacy: .public) size=\(maxDim)px")
        let result = await serverFetch(coverArtId: coverArtId, key: key, tier: tier)
        await fetchGate.release()
        return result
    }

    private func serverFetch(coverArtId: String, key: String, tier: ArtworkTier) async -> PlatformImage? {
        let maxDim = tier.decodePixels
        guard let serverURL = await libraryService.coverArtURL(id: coverArtId, size: maxDim) else { return nil }
        let t0 = Date()
        guard let (data, response) = try? await session.data(from: serverURL) else {
            Logger.artworkCache.warning("[NET-COVER] failed id=\(coverArtId, privacy: .public) duration=\(Int(Date().timeIntervalSince(t0) * 1000))ms")
            return nil
        }
        let image = await Task.detached(priority: .utility) {
            ArtworkImageCache.thumbnailImage(from: data, maxDimension: maxDim)
        }.value
        guard let image else {
            Logger.artworkCache.warning("[NET-COVER] failed (decode) id=\(coverArtId, privacy: .public) duration=\(Int(Date().timeIntervalSince(t0) * 1000))ms")
            return nil
        }
        Logger.artworkCache.debug("[NET-COVER] done id=\(coverArtId, privacy: .public) tier=\(tier.rawValue, privacy: .public) duration=\(Int(Date().timeIntervalSince(t0) * 1000))ms bytes=\(data.count, privacy: .public)")
        store(image: image, forKey: key)
        if persistCoversEnabled {
            await downloadService.persistCover(data, forId: "\(coverArtId)@\(tier.rawValue)")
        }
        if let http = response as? HTTPURLResponse {
            revalidationStore.record(id: coverArtId, lastModified: http.value(forHTTPHeaderField: "Last-Modified"))
        }
        return image
    }

    // MARK: - Revalidation

    /// Fires a background re-check of `coverArtId` when its TTL has lapsed. Non-blocking: the caller
    /// has already returned the cached image, so this is pure stale-while-revalidate — the view
    /// keeps the old cover until (and unless) a change is found.
    private func revalidateIfDue(coverArtId: String, tier: ArtworkTier) {
        guard !revalidating.contains(coverArtId),
              !revalidationDeferred.contains(coverArtId),
              revalidationStore.isDue(id: coverArtId) else { return }
        revalidating.insert(coverArtId)
        Task { await self.revalidate(coverArtId: coverArtId, tier: tier) }
    }

    private func revalidate(coverArtId: String, tier: ArtworkTier) async {
        defer { revalidating.remove(coverArtId) }
        guard let url = await libraryService.coverArtURL(id: coverArtId, size: tier.decodePixels) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else {
            // Avoid a HEAD request per row while offline.
            revalidationDeferred.insert(coverArtId)
            return
        }

        let serverLM = http.value(forHTTPHeaderField: "Last-Modified")
        switch CoverRevalidationOutcome.decide(stored: revalidationStore.lastModified(for: coverArtId), server: serverLM) {
        case .baseline, .unchanged, .indeterminate:
            revalidationStore.record(id: coverArtId, lastModified: serverLM)
        case .changed:
            Logger.artworkCache.info("[REVAL] cover changed id=\(coverArtId, privacy: .public) — refetching")
            await refetchChangedCover(coverArtId: coverArtId, tier: tier, newLastModified: serverLM)
        }
    }

    /// Replaces every cached copy of a cover that changed on the server, then nudges the UI to
    /// re-read it. The tier that triggered the check is fetched now; the other tier is dropped so it
    /// re-fetches fresh on its next access.
    private func refetchChangedCover(coverArtId: String, tier: ArtworkTier, newLastModified: String?) async {
        for staleTier in [ArtworkTier.thumb, .hero] {
            let staleKey = cacheKey(id: coverArtId, tier: staleTier)
            cache.removeValue(forKey: staleKey)
            accessOrder.removeAll { $0 == staleKey }
            await downloadService.removeCover(forId: staleKey)
        }
        _ = await serverFetch(coverArtId: coverArtId, key: cacheKey(id: coverArtId, tier: tier), tier: tier)
        revalidationStore.record(id: coverArtId, lastModified: newLastModified)
        let key = "coverArtUploadVersion"
        UserDefaults.standard.set(UserDefaults.standard.integer(forKey: key) + 1, forKey: key)
    }

    func invalidate(for coverArtId: String) async {
        for key in ["\(coverArtId)@thumb", "\(coverArtId)@hero", coverArtId] {
            cache.removeValue(forKey: key)
            accessOrder.removeAll { $0 == key }
            await downloadService.removeCover(forId: key)
        }
        Logger.artworkCache.debug("ArtworkImageCache: invalidated \(coverArtId, privacy: .public) (RAM + disk)")
    }

    func clearCache() {
        cache.removeAll()
        accessOrder.removeAll()
    }

    /// Forgets all revalidation metadata. Called from the version-bump disk wipe so a fresh cache
    /// doesn't carry `Last-Modified` values describing images that were just deleted.
    func clearRevalidationMetadata() {
        revalidationStore.removeAll()
        revalidating.removeAll()
        revalidationDeferred.removeAll()
    }

    // MARK: - Private

    private func cacheKey(id: String, tier: ArtworkTier) -> String {
        "\(id)@\(tier.rawValue)"
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
