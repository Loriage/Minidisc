import Foundation
import SwiftData
import Synchronization
import Testing
import UIKit
@testable import Minidisc

@Suite("Offline artwork quality")
@MainActor
struct ArtworkQualityTests {
    @Test func selectionSurvivesRelaunchAndDefaultsToStandard() throws {
        let name = "artwork-quality-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = CacheSettings(defaults: defaults)
        #expect(settings.artworkQuality == .standard)
        settings.artworkQuality = .original
        #expect(CacheSettings(defaults: defaults).artworkQuality == .original)
    }

    @Test(arguments: [ArtworkQuality.high, .original])
    func upgradesExistingCoversOnceAndPreservesOriginalBytes(quality: ArtworkQuality) async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let old = imageData(color: .red)
        let new = imageData(color: .blue)
        let covers = fixture.base.appendingPathComponent("coverarts")
        try FileManager.default.createDirectory(at: covers, withIntermediateDirectories: true)
        try old.write(to: covers.appendingPathComponent("cover"))
        try old.write(to: covers.appendingPathComponent("cover@hero"))
        let requests = Mutex<[URLRequest]>([])
        let loader: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
            requests.withLock { $0.append(request) }
            return (new, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let downloads = DownloadService(serverService: fixture.server, modelContainer: fixture.models,
            toastService: ToastService(), baseDirectory: fixture.base, coverDataLoader: loader,
            artworkQuality: { quality })

        #expect(await downloads.healMissingDownloadedCovers(serverID: fixture.serverID,
            allowsCellular: false, shouldContinue: { true }) == 1)
        #expect(try Data(contentsOf: covers.appendingPathComponent("cover")) == new)
        #expect(!FileManager.default.fileExists(atPath: covers.appendingPathComponent("cover@hero").path))
        let request = try #require(requests.withLock { $0.first })
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
        #expect(query?.first { $0.name == "size" }?.value == quality.pixels.map(String.init))
        #expect(!request.allowsCellularAccess && !request.allowsExpensiveNetworkAccess)

        let relaunched = DownloadService(serverService: fixture.server, modelContainer: fixture.models,
            toastService: ToastService(), baseDirectory: fixture.base, coverDataLoader: loader,
            artworkQuality: { quality })
        #expect(await relaunched.healMissingDownloadedCovers(serverID: fixture.serverID,
            allowsCellular: false, shouldContinue: { true }) == 0)
        #expect(requests.withLock { $0.count } == 1)
        await relaunched.clearStreamingCovers()
        #expect(try Data(contentsOf: covers.appendingPathComponent("cover")) == new)
    }

    @Test(arguments: [200, 503])
    func failedUpgradePreservesExistingArtwork(status: Int) async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let covers = fixture.base.appendingPathComponent("coverarts")
        try FileManager.default.createDirectory(at: covers, withIntermediateDirectories: true)
        let old = imageData(color: .red)
        try old.write(to: covers.appendingPathComponent("cover"))
        try old.write(to: covers.appendingPathComponent("cover@hero"))
        let downloads = DownloadService(serverService: fixture.server, modelContainer: fixture.models,
            toastService: ToastService(), baseDirectory: fixture.base, coverDataLoader: { request in
                (Data("Not an image".utf8), HTTPURLResponse(url: request.url!, statusCode: status,
                    httpVersion: nil, headerFields: nil)!)
            }, artworkQuality: { .high })

        #expect(await downloads.healMissingDownloadedCovers(serverID: fixture.serverID,
            allowsCellular: false, shouldContinue: { true }) == 0)
        #expect(try Data(contentsOf: covers.appendingPathComponent("cover")) == old)
        #expect(try Data(contentsOf: covers.appendingPathComponent("cover@hero")) == old)
    }

    @Test func automaticUpgradesWaitForAnAllowedConnection() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let name = "artwork-sync-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = CacheSettings(defaults: defaults)
        settings.artworkQuality = .high
        let state = ServerState()
        state.activeServer = fixture.snapshot
        let requests = Mutex(0)
        let data = imageData(color: .blue)
        let downloads = DownloadService(serverService: fixture.server, modelContainer: fixture.models,
            toastService: ToastService(), baseDirectory: fixture.base, coverDataLoader: { request in
                requests.withLock { $0 += 1 }
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }, artworkQuality: { await settings.artworkQuality })
        let cache = ArtworkImageCache(coverArtURLProvider: { _, _ in nil },
            dataLoader: { _ in throw URLError(.notConnectedToInternet) },
            imageDecoder: { data, _ in UIImage(data: data) })
        let sync = OfflineArtworkSync(state: state, settings: settings, downloads: downloads,
                                      artwork: cache, defaults: defaults)
        sync.isReady = true
        await sync.synchronize()
        #expect(requests.withLock { $0 } == 0)
        state.applyNetworkPath(.init(generation: 1, descriptor: path(expensive: true)))
        await sync.synchronize()
        #expect(requests.withLock { $0 } == 0)
        settings.cacheOverCellular = true
        state.applyNetworkPath(.init(generation: 2, descriptor: path(constrained: true)))
        await sync.synchronize()
        #expect(requests.withLock { $0 } == 0)
        state.applyNetworkPath(.init(generation: 3, descriptor: path()))
        state.isOfflineModeEnabled = true
        await sync.synchronize()
        #expect(requests.withLock { $0 } == 0)
        state.isOfflineModeEnabled = false
        await sync.synchronize()
        #expect(requests.withLock { $0 } == 1)
        settings.artworkQuality = .original
        await sync.synchronize()
        #expect(requests.withLock { $0 } == 2)
        settings.artworkQuality = .standard
        await sync.synchronize()
        #expect(requests.withLock { $0 } == 2)
    }

    private func path(expensive: Bool = false, constrained: Bool = false) -> NetworkPathDescriptor {
        NetworkPathDescriptor(isOnline: true, isExpensive: expensive, isConstrained: constrained,
            supportsDNS: true, supportsIPv4: true, supportsIPv6: true,
            interfaces: expensive ? .cellular : .wifi, gateways: [])
    }

    private func imageData(color: UIColor) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).pngData { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
    }

    private func makeFixture() throws -> (base: URL, server: MockServerService, models: ModelContainer, serverID: UUID, snapshot: ServerSnapshot) {
        let base = URL.temporaryDirectory.appendingPathComponent("cover-quality-\(UUID())")
        let models = try ModelContainer.minidisc(inMemory: true)
        let server = MockServerService()
        let snapshot = ServerSnapshot(from: ServerConfig(displayName: "Test", baseURL: "https://example.invalid", username: "test"))
        server.connection = try ServerConnection(version: .init(serverID: snapshot.id, revision: 1), server: snapshot,
            credentials: .init(password: "test", customHeaders: [:]))
        models.mainContext.insert(DownloadedTrack(songId: "song", serverId: snapshot.id, filePath: "unused",
            fileSize: 1, mimeType: "audio/mpeg", title: "Track", coverArtId: "cover"))
        try models.mainContext.save()
        return (base, server, models, snapshot.id, snapshot)
    }
}
