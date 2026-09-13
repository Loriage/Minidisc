import Foundation
import Testing
import UIKit
@testable import Minidisc

@Suite("Transient Navidrome artwork")
struct ArtworkResponsePolicyTests {
    @Test(arguments: [
        ("no-store", true), ("private, No-Store", true),
        ("public, no-cache", false), ("public, max-age=31536000, immutable", false)
    ])
    func followsCacheControl(value: String, expected: Bool) {
        let response = HTTPURLResponse(url: URL(string: "https://example.invalid/cover")!, statusCode: 200,
                                       httpVersion: nil, headerFields: ["Cache-Control": value])!
        #expect(ArtworkResponsePolicy.isTransient(response) == expected)
    }

    @MainActor
    @Test func placeholderIsNotPersistedAndNextLoadFetchesRealArtwork() async {
        let responses = ArtworkResponseSequence()
        let suite = "ArtworkResponsePolicyTests.\(UUID())"
        let metadata = URL.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: metadata) }
        let cache = ArtworkImageCache(revalidationStore: CoverRevalidationStore(fileURL: metadata),
            coverArtURLProvider: { _, _ in URL(string: "https://example.invalid/cover")! },
            persistCoverOperation: { _, _ in await responses.persist() },
            dataLoader: { await responses.load($0) }, imageDecoder: { _, _ in UIImage() })
        #expect(await cache.load(coverArtId: "ar-test") == nil)
        #expect(cache.cachedImage(for: "ar-test") == nil)
        #expect(await responses.saved == 0)
        #expect(await cache.load(coverArtId: "ar-test") != nil)
        #expect(cache.cachedImage(for: "ar-test") != nil)
        #expect(await responses.calls == 2)
        #expect(await responses.saved == 1)
    }
}

private actor ArtworkResponseSequence {
    private(set) var calls = 0
    private(set) var saved = 0
    func persist() { saved += 1 }
    func load(_ request: URLRequest) -> (Data, URLResponse) {
        calls += 1
        let headers = ["Cache-Control": calls == 1 ? "no-store" : "public, max-age=31536000, immutable"]
        return (Data([1]), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!)
    }
}
