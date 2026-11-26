import Foundation
import MediaPlayer
import Testing
import UIKit
@testable import Minidisc

@Suite("Offline artwork", .serialized)
@MainActor
struct OfflineArtworkTests {
    @Test(arguments: ["cover", "cover@hero", "cover@thumb", "cover@standard@hero", "cover@high@hero", "cover@original@thumb"])
    func coldCacheUsesAvailableDiskArtwork(diskID: String) async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try imageData().write(to: directory.appendingPathComponent(diskID))
        let cache = makeCache(directory: directory)

        let image = await cache.load(coverArtId: "cover", tier: .hero)

        #expect(image != nil)
    }

    @Test func systemPlayerUsesDownloadedArtworkWithoutOpeningFullPlayer() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try imageData().write(to: directory.appendingPathComponent("cover"))
        let cache = makeCache(directory: directory)
        let player = MockPlayerService()
        let presenter = NowPlayingCenterPresenter()
        let service = NowPlayingService(playerService: player, artworkImageCache: cache, presenter: presenter)
        let snapshot = NowPlayingSnapshot(title: "Offline track", artist: "Artist", album: "Album",
            duration: 180, position: 0, playbackRate: 1, artworkURL: nil, artworkHeaders: [:],
            coverArtId: "cover", isLiveStream: false, radioStationName: nil, songId: "track")

        await service.update(with: snapshot)

        #expect(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] != nil)
        await service.pushPosition(elapsed: 30, rate: 1, duration: 180, songId: "track")
        #expect(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] != nil)
        await service.stop()
    }

    private func makeDirectory() throws -> URL {
        let directory = URL.temporaryDirectory.appendingPathComponent("offline-artwork-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func imageData() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).pngData { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
    }

    private func makeCache(directory: URL) -> ArtworkImageCache {
        let cache = ArtworkImageCache(coverArtURLProvider: { _, _ in
            Issue.record("Offline artwork must not resolve a server URL")
            return nil
        }, localCoverURLProvider: { id in
            let url = directory.appendingPathComponent(id)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }, dataLoader: { _ in
            Issue.record("Offline artwork must not request the network")
            throw URLError(.notConnectedToInternet)
        }, imageDecoder: { data, pixels in
            ArtworkImageCache.thumbnailImage(from: data, maxDimension: pixels)
        })
        cache.networkAccessAllowed = { false }
        return cache
    }
}
