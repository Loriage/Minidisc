import Foundation
import SwiftData
import Synchronization
import Testing
@testable import Minidisc

@Suite("Downloaded covers survive cache maintenance")
@MainActor
struct DownloadedCoverRepairTests {
    @Test func cachePurgePreservesOfflineCoversAndGarbageCollectionPreservesVariants() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("covers-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let covers = base.appendingPathComponent("coverarts")
        try FileManager.default.createDirectory(at: covers, withIntermediateDirectories: true)
        for name in ["owned", "orphan", "owned@thumb", "orphan@hero"] {
            try Data([1, 2, 3]).write(to: covers.appendingPathComponent(name))
        }
        let downloads = DownloadService(serverService: MockServerService(),
            modelContainer: try ModelContainer.minidisc(inMemory: true), toastService: ToastService(), baseDirectory: base)
        #expect(await downloads.garbageCollectOrphanedCovers(referencedIds: ["owned"]) == 1)
        #expect(try names(in: covers) == ["owned", "owned@thumb", "orphan@hero"])
        let before = await downloads.coverCacheStats()
        #expect(before.count == 2 && before.bytes == 6)
        await downloads.clearStreamingCovers()
        #expect(try names(in: covers) == ["owned"])
        let after = await downloads.coverCacheStats()
        #expect(after.count == 0 && after.bytes == 0)
        #expect(try Data(contentsOf: covers.appendingPathComponent("owned")) == Data([1, 2, 3]))
    }

    @Test func repairUsesOnlyOwnedMissingCoversAndRespectsNetworkPolicy() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("covers-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let covers = base.appendingPathComponent("coverarts")
        try FileManager.default.createDirectory(at: covers, withIntermediateDirectories: true)
        let models = try ModelContainer.minidisc(inMemory: true)
        let server = MockServerService()
        let snapshot = ServerSnapshot(from: ServerConfig(displayName: "Test", baseURL: "https://example.invalid", username: "test"))
        server.connection = try ServerConnection(version: .init(serverID: snapshot.id, revision: 1), server: snapshot,
            credentials: .init(password: "test", customHeaders: ["X-Cover-Test": "fixture"]))
        insert(models, server: snapshot.id, cover: "missing")
        insert(models, server: snapshot.id, cover: "present")
        insert(models, server: snapshot.id, cover: "empty")
        insert(models, server: UUID(), cover: "another-server")
        try models.mainContext.save()
        try Data([9]).write(to: covers.appendingPathComponent("present"))
        try Data().write(to: covers.appendingPathComponent("empty"))
        let requests = Mutex<[URLRequest]>([])
        let downloads = DownloadService(serverService: server, modelContainer: models, toastService: ToastService(),
            baseDirectory: base, coverDataLoader: { request in
                requests.withLock { $0.append(request) }
                return (Data([1]), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
        #expect(await downloads.healMissingDownloadedCovers(serverID: snapshot.id, allowsCellular: false,
                                                           shouldContinue: { false }) == 0)
        #expect(requests.withLock { $0.isEmpty })
        #expect(await downloads.healMissingDownloadedCovers(serverID: snapshot.id, allowsCellular: false,
                                                           shouldContinue: { true }) == 2)
        #expect(try names(in: covers) == ["missing", "present", "empty"])
        let sent = requests.withLock { $0 }
        #expect(sent.count == 2)
        #expect(sent.allSatisfy { !$0.allowsCellularAccess && !$0.allowsExpensiveNetworkAccess && !$0.allowsConstrainedNetworkAccess })
        #expect(sent.allSatisfy { $0.value(forHTTPHeaderField: "X-Cover-Test") == "fixture" })
        #expect(await downloads.healMissingDownloadedCovers(serverID: snapshot.id, allowsCellular: false,
                                                           shouldContinue: { true }) == 0)
    }

    @Test func aDeletedDownloadCannotBeRecreatedByAnInFlightRepair() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("covers-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let models = try ModelContainer.minidisc(inMemory: true)
        let server = MockServerService()
        let snapshot = ServerSnapshot(from: ServerConfig(displayName: "Test", baseURL: "https://example.invalid", username: "test"))
        server.connection = try ServerConnection(version: .init(serverID: snapshot.id, revision: 1), server: snapshot,
            credentials: .init(password: "test", customHeaders: [:]))
        insert(models, server: snapshot.id, cover: "removed")
        try models.mainContext.save()
        let downloads = DownloadService(serverService: server, modelContainer: models, toastService: ToastService(),
            baseDirectory: base, coverDataLoader: { request in
                try await MainActor.run {
                    try models.mainContext.delete(model: DownloadedTrack.self)
                    try models.mainContext.save()
                }
                return (Data([1]), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
        #expect(await downloads.healMissingDownloadedCovers(serverID: snapshot.id, allowsCellular: true,
                                                           shouldContinue: { true }) == 0)
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("coverarts/removed").path))
    }

    private func insert(_ models: ModelContainer, server: UUID, cover: String) {
        models.mainContext.insert(DownloadedTrack(songId: cover, serverId: server, filePath: "unused",
            fileSize: 1, mimeType: "audio/mpeg", title: cover, coverArtId: cover))
    }

    private func names(in directory: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
    }
}
