import Foundation
import Synchronization
import Testing
import UIKit
@testable import Minidisc

nonisolated private final class ArtworkRequestLog: Sendable {
    let requests = Mutex<[URLRequest]>([])
    let fails = Mutex(false)

    func load(_ request: URLRequest, data: Data) throws -> (Data, URLResponse) {
        requests.withLock { $0.append(request) }
        if fails.withLock({ $0 }) { throw URLError(.notConnectedToInternet) }
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200,
                                     httpVersion: nil, headerFields: nil)!)
    }

    var sizes: [String?] {
        requests.withLock { requests in
            requests.map { request in
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "size" }?.value
            }
        }
    }
}

@MainActor
@Suite("Online artwork quality")
struct OnlineArtworkQualityTests {
    @Test(arguments: ArtworkQuality.allCases, [ArtworkTier.thumb, .hero])
    func serverRequestsUseSelectedQuality(quality: ArtworkQuality, tier: ArtworkTier) async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let requests = ArtworkRequestLog()
        let data = imageData(.blue)
        let cache = makeCache(directory, requests: requests, data: data)
        cache.quality = quality

        #expect(await cache.load(coverArtId: "cover", tier: tier) != nil)
        #expect(requests.sizes == [quality.pixels.map(String.init)])
        let stored = directory.appendingPathComponent("cover@\(quality.rawValue)@\(tier.rawValue)")
        #expect(try Data(contentsOf: stored) == data)
    }

    @Test func qualityChangesAndRelaunchDoNotReuseLowerQuality() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let requests = ArtworkRequestLog()
        let data = imageData(.blue)
        let cache = makeCache(directory, requests: requests, data: data)
        for quality in ArtworkQuality.allCases {
            cache.quality = quality
            #expect(await cache.load(coverArtId: "cover", tier: .hero) != nil)
        }
        #expect(requests.sizes == ["600", "1200", nil])

        let relaunched = makeCache(directory, requests: requests, data: data)
        relaunched.quality = .original
        #expect(await relaunched.load(coverArtId: "cover", tier: .hero) != nil)
        relaunched.quality = .standard
        #expect(await relaunched.load(coverArtId: "cover", tier: .hero) != nil)
        #expect(requests.sizes.count == 3)
    }

    @Test func fullPlayerReusesSourceFetchedForThumbnail() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let requests = ArtworkRequestLog()
        let cache = makeCache(directory, requests: requests, data: imageData(.blue))
        cache.quality = .original
        #expect(await cache.load(coverArtId: "cover", tier: .thumb) != nil)
        #expect(await cache.load(coverArtId: "cover", tier: .hero) != nil)
        #expect(requests.sizes == [nil])
    }

    @Test func failedUpgradeKeepsFallbackWithoutPreventingRetry() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let previous = imageData(.red)
        let stored = directory.appendingPathComponent("cover@standard@hero")
        try previous.write(to: stored)
        let requests = ArtworkRequestLog()
        requests.fails.withLock { $0 = true }
        let cache = makeCache(directory, requests: requests, data: imageData(.blue))
        cache.quality = .original

        #expect(await cache.load(coverArtId: "cover", tier: .hero) != nil)
        #expect(cache.cachedImage(for: "cover", tier: .hero) == nil)
        #expect(try Data(contentsOf: stored) == previous)
        requests.fails.withLock { $0 = false }
        #expect(await cache.load(coverArtId: "cover", tier: .hero) != nil)
        #expect(requests.sizes == [nil, nil])
        #expect(cache.cachedImage(for: "cover", tier: .hero) != nil)
    }

    @Test(arguments: [ArtworkQuality.standard, .original])
    func downloadedArtworkMustMeetOnlineQuality(downloadedQuality: ArtworkQuality) async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = imageData(.red)
        let downloaded = directory.appendingPathComponent("cover")
        try data.write(to: downloaded)
        let requests = ArtworkRequestLog()
        let cache = makeCache(directory, requests: requests, data: imageData(.blue),
                              downloadedQuality: downloadedQuality)
        cache.quality = .original

        #expect(await cache.load(coverArtId: "cover", tier: .hero) != nil)
        #expect(requests.sizes.count == (downloadedQuality == .original ? 0 : 1))
        #expect(try Data(contentsOf: downloaded) == data)
        try CoverArtFiles.clearStreamingVariants(in: directory)
        #expect(try Data(contentsOf: downloaded) == data)
        cache.clearCache()
        cache.networkAccessAllowed = { false }
        #expect(await cache.load(coverArtId: "cover", tier: .hero) != nil)
        #expect(requests.sizes.count == (downloadedQuality == .original ? 0 : 1))
    }

    @Test func invalidationRemovesEveryQualityAndLegacyVariant() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = imageData(.blue)
        let ids = CoverArtFiles.streamingVariantIDs(for: "cover") + ["cover"]
        for id in ids { try data.write(to: directory.appendingPathComponent(id)) }
        let cache = makeCache(directory, requests: ArtworkRequestLog(), data: data)
        await cache.invalidate(for: "cover")
        #expect(ids.allSatisfy { !FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) })
    }

    private func makeDirectory() throws -> URL {
        let directory = URL.temporaryDirectory.appendingPathComponent("online-artwork-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func imageData(_ color: UIColor) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).pngData { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
    }

    private func makeCache(_ directory: URL, requests: ArtworkRequestLog, data: Data,
                           downloadedQuality: ArtworkQuality = .standard) -> ArtworkImageCache {
        let store = CoverRevalidationStore(fileURL: directory.appendingPathComponent("revalidation.json"))
        store.record(id: "cover", lastModified: nil)
        store.flush()
        return ArtworkImageCache(revalidationStore: store, coverArtURLProvider: { id, pixels in
            var url = URLComponents(string: "https://example.invalid/cover")!
            url.queryItems = [URLQueryItem(name: "id", value: id)]
            if let pixels { url.queryItems?.append(URLQueryItem(name: "size", value: String(pixels))) }
            return url.url
        }, localCoverURLProvider: { id in
            let url = directory.appendingPathComponent(id)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }, localCoverQualityProvider: { _ in downloadedQuality },
           persistCoverOperation: { data, id in
            try? data.write(to: directory.appendingPathComponent(id), options: .atomic)
        }, removeCoverOperation: { id in
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(id))
        }, dataLoader: { request in
            try requests.load(request, data: data)
        }, imageDecoder: { data, pixels in
            ArtworkImageCache.thumbnailImage(from: data, maxDimension: pixels)
        })
    }
}
