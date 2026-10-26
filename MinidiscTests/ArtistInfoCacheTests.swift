import Foundation
import SwiftData
import SwiftSonic
import Testing
@testable import Minidisc

@Suite("LibraryService artist info cache")
@MainActor
struct ArtistInfoCacheTests {
    @Test func reusesOnlyMatchingArtistAndCount() async throws {
        let fixture = try Fixture()
        let first = try await fixture.service.getArtistInfo(forArtistID: "42", count: 1)
        let cached = try await fixture.service.getArtistInfo(forArtistID: "42", count: 1)
        #expect(first.biography == "A:42")
        #expect(cached.biography == first.biography)
        #expect(await fixture.firstTransport.requestCount == 1)

        let larger = try await fixture.service.getArtistInfo(forArtistID: "42", count: 3)
        let other = try await fixture.service.getArtistInfo(forArtistID: "43", count: 1)
        #expect(larger.similarArtist?.count == 3)
        #expect(other.biography == "A:43")
        #expect(await fixture.firstTransport.requestCount == 3)
    }

    @Test(arguments: [false, true])
    func cachedEntryDoesNotSurviveConnectionChange(sameServer: Bool) async throws {
        let fixture = try Fixture(sameServer: sameServer)
        _ = try await fixture.service.getArtistInfo(forArtistID: "42", count: 1)
        fixture.server.connection = fixture.secondConnection

        let fresh = try await fixture.service.getArtistInfo(forArtistID: "42", count: 1)
        let cached = try await fixture.service.getArtistInfo(forArtistID: "42", count: 1)
        #expect(fresh.biography == "B:42")
        #expect(cached.biography == "B:42")
        #expect(await fixture.firstTransport.requestCount == 1)
        #expect(await fixture.secondTransport.requestCount == 1)
    }

    @Test(arguments: [false, true])
    func lateResponseCannotReplaceTheNewConnectionsCache(sameServer: Bool) async throws {
        let fixture = try Fixture(sameServer: sameServer, holdFirstRequest: true)
        let stale = Task { try await fixture.service.getArtistInfo(forArtistID: "42", count: 1) }
        await fixture.firstTransport.waitUntilFirstRequestStarted()
        fixture.server.connection = fixture.secondConnection

        let fresh = try await fixture.service.getArtistInfo(forArtistID: "42", count: 1)
        await fixture.firstTransport.releaseFirstResponse()
        await #expect(throws: CancellationError.self) { try await stale.value }
        let cached = try await fixture.service.getArtistInfo(forArtistID: "42", count: 1)
        #expect(fresh.biography == "B:42")
        #expect(cached.biography == "B:42")
        #expect(await fixture.secondTransport.requestCount == 1)
    }

    @Test func cancelledResponseIsNotCached() async throws {
        let fixture = try Fixture(holdFirstRequest: true)
        let cancelled = Task { try await fixture.service.getArtistInfo(forArtistID: "42", count: 1) }
        await fixture.firstTransport.waitUntilFirstRequestStarted()
        cancelled.cancel()
        await fixture.firstTransport.releaseFirstResponse()
        await #expect(throws: CancellationError.self) { try await cancelled.value }

        _ = try await fixture.service.getArtistInfo(forArtistID: "42", count: 1)
        #expect(await fixture.firstTransport.requestCount == 2)
    }

    @Test func cancelledCallerCannotReadCachedInfo() async throws {
        let fixture = try Fixture()
        _ = try await fixture.service.getArtistInfo(forArtistID: "42", count: 1)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fixture.service.getArtistInfo(forArtistID: "42", count: 1)
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(await fixture.firstTransport.requestCount == 1)
    }

    @Test func disconnectedServerCannotReadCachedInfo() async throws {
        let fixture = try Fixture()
        _ = try await fixture.service.getArtistInfo(forArtistID: "42", count: 1)
        fixture.server.connection = nil
        await #expect(throws: (any Error).self) {
            try await fixture.service.getArtistInfo(forArtistID: "42", count: 1)
        }
        #expect(await fixture.firstTransport.requestCount == 1)
    }

    private struct Fixture {
        let server: MockServerService
        let service: LibraryService
        let secondConnection: ServerConnection
        let firstTransport: ArtistInfoTransport
        let secondTransport: ArtistInfoTransport

        init(sameServer: Bool = false, holdFirstRequest: Bool = false) throws {
            let server = MockServerService()
            let first = try Self.connection(serverID: UUID(), revision: 1)
            let second = try Self.connection(serverID: sameServer ? first.version.serverID : UUID(), revision: 2)
            server.connection = first
            let firstTransport = ArtistInfoTransport(label: "A", holdFirstRequest: holdFirstRequest)
            let secondTransport = ArtistInfoTransport(label: "B")
            let models = try ModelContainer.minidisc(inMemory: true)
            let index = LibraryIndexStore(modelContainer: try ModelContainer.libraryIndex(inMemory: true))
            let source = SwiftSonicLibrarySource(serverService: server)
            let catalog = LibraryCatalog(source: source, store: index,
                synchronizer: LibraryIndexSynchronizer(source: source, store: index))
            self.server = server
            self.secondConnection = second
            self.firstTransport = firstTransport
            self.secondTransport = secondTransport
            service = LibraryService(serverService: server, modelContainer: models,
                downloadService: DownloadService(serverService: server, modelContainer: models, toastService: ToastService()),
                statsService: StatsService(modelContainer: models), catalog: catalog, indexStore: index,
                clientFactory: { connection in
                    SwiftSonicClient(
                        configuration: ServerConfiguration(serverURL: connection.baseURL,
                            username: connection.server.username, password: connection.credentials.password),
                        transport: connection.version == first.version ? firstTransport : secondTransport,
                        retryPolicy: .none)
                })
        }

        private static func connection(serverID: UUID, revision: UInt64) throws -> ServerConnection {
            let snapshot = ServerSnapshot(from: ServerConfig(id: serverID, displayName: "Fixture",
                baseURL: "https://example.invalid", username: "fixture"))
            return try ServerConnection(version: .init(serverID: serverID, revision: revision),
                server: snapshot, credentials: ServerCredentials(password: "fixture", customHeaders: [:]))
        }
    }
}

private actor ArtistInfoTransport: HTTPTransport {
    private let label: String
    private let holdFirstRequest: Bool
    private var responseContinuation: CheckedContinuation<Void, Never>?
    private var startContinuation: CheckedContinuation<Void, Never>?
    private(set) var requestCount = 0

    init(label: String, holdFirstRequest: Bool = false) {
        self.label = label
        self.holdFirstRequest = holdFirstRequest
    }

    func waitUntilFirstRequestStarted() async {
        guard requestCount == 0 else { return }
        await withCheckedContinuation { startContinuation = $0 }
    }

    func releaseFirstResponse() {
        responseContinuation?.resume()
        responseContinuation = nil
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        #expect(url.deletingPathExtension().lastPathComponent == "getArtistInfo2")
        let query = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            + (request.httpBody.flatMap { String(data: $0, encoding: .utf8) }
                .flatMap { URLComponents(string: "?" + $0)?.queryItems } ?? [])
        let artistID = try #require(query.first { $0.name == "id" }?.value)
        let count = try #require(query.first { $0.name == "count" }?.value.flatMap(Int.init))
        requestCount += 1
        startContinuation?.resume()
        startContinuation = nil
        if holdFirstRequest, requestCount == 1 {
            await withCheckedContinuation { responseContinuation = $0 }
        }
        let info: [String: Any] = [
            "biography": "\(label):\(artistID)",
            "similarArtist": (0..<count).map { ["id": "\($0)", "name": "Artist \($0)"] }
        ]
        let data = try JSONSerialization.data(withJSONObject: [
            "subsonic-response": ["status": "ok", "version": "1.16.1", "artistInfo2": info]
        ])
        return (data, try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
    }
}
