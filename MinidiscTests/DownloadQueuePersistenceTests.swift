import Foundation
import SwiftSonic
import Testing
@testable import Minidisc

private actor QueueTestTransport: DownloadTransport {
    nonisolated let events: AsyncStream<DownloadTransportEvent>
    private let channel: AsyncStream<DownloadTransportEvent>.Continuation
    private(set) var requests: [UUID: URLRequest] = [:]
    private(set) var cancelled: Set<UUID> = []
    private(set) var acknowledged: Set<UUID> = []
    var active: Set<UUID>
    private let receipts: [CompletedDownload]

    init(active: Set<UUID> = [], receipts: [CompletedDownload] = []) {
        let stream = AsyncStream<DownloadTransportEvent>.makeStream()
        events = stream.stream
        channel = stream.continuation
        self.active = active
        self.receipts = receipts
    }
    func activeJobIDs() async -> Set<UUID> { active }
    func start(jobID: UUID, request: URLRequest) async { requests[jobID] = request; active.insert(jobID) }
    func cancel(jobID: UUID) async { cancelled.insert(jobID); active.remove(jobID) }
    func completedTransfers() async -> [CompletedDownload] { receipts }
    func fileURL(jobID: UUID) async -> URL { URL.temporaryDirectory.appendingPathComponent(jobID.uuidString) }
    func acknowledge(jobID: UUID) async { acknowledged.insert(jobID); active.remove(jobID) }
    func emit(_ event: DownloadTransportEvent) { channel.yield(event) }
}

private actor QueueTestStorage {
    private(set) var saved: Set<String> = []
    var shouldFail = false
    var blockCommit = false
    private var lookupWaiter: CheckedContinuation<Void, Never>?
    var blockLookup = false
    var isLookingUp: Bool { lookupWaiter != nil }
    private var waiter: CheckedContinuation<Void, Never>?
    var isCommitting: Bool { waiter != nil }
    func configure(fail: Bool = false, block: Bool = false) { shouldFail = fail; blockCommit = block }
    func commit(_ id: String) async throws {
        if blockCommit { await withCheckedContinuation { waiter = $0 } }
        try Task.checkCancellation()
        if shouldFail { throw UserFacingError.downloadFailed }
        saved.insert(id)
    }
    func release() { waiter?.resume(); waiter = nil }
    func configureLookup() { blockLookup = true }
    func lookup(_ id: String) async -> Bool {
        if blockLookup { await withCheckedContinuation { lookupWaiter = $0 } }
        return saved.contains(id)
    }
    func releaseLookup() { lookupWaiter?.resume(); lookupWaiter = nil; blockLookup = false }
}

@Suite @MainActor
struct DownloadQueuePersistenceTests {
    private func connection(serverID: UUID) throws -> ServerConnection {
        let snapshot = ServerSnapshot(from: ServerConfig(id: serverID, displayName: "Test", baseURL: "https://download.invalid", username: "test"))
        return try ServerConnection(version: .init(serverID: serverID, revision: 1), server: snapshot,
                                    credentials: .init(password: "secret", customHeaders: [:]))
    }

    private func songs(_ ids: [String]) throws -> [Song] {
        try ids.map { try JSONDecoder().decode(Song.self, from: Data("{\"id\":\"\($0)\",\"title\":\"Track\",\"isDir\":false,\"duration\":10}".utf8)) }
    }

    private func controller(at journal: URL, transport: QueueTestTransport, storage: QueueTestStorage,
                            serverID: UUID, connectionID: UUID? = nil) throws -> DownloadQueueController {
        let connection = try connection(serverID: connectionID ?? serverID)
        return DownloadQueueController(journalURL: journal, transport: transport,
            connection: { _ in connection },
            isDownloaded: { id, _ in await storage.lookup(id) },
            commit: { song, _, _, _ in try await storage.commit(song.id) }, onProgress: { _ in })
    }

    private func wait(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(await condition())
    }

    @Test func allCollectionMembersArePersistedAndReattachWithoutDuplicateTransfers() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = root.appendingPathComponent("queue.json")
        let server = UUID(), transport = QueueTestTransport(), storage = QueueTestStorage()
        let queue = try controller(at: journal, transport: transport, storage: storage, serverID: server)
        let tracks = try songs((0..<12).map(String.init))
        try await queue.enqueue(tracks, serverID: server, owner: .playlist("p"))
        try await queue.enqueue([tracks[0]], serverID: server, owner: .album("a"))
        let pending = await queue.snapshot()
        #expect(pending.count == 12)
        #expect(await transport.requests.count == 12)
        let data = try Data(contentsOf: journal)
        #expect(try JSONDecoder().decode([QueuedDownload].self, from: data).count == 12)
        #expect(!String(decoding: data, as: UTF8.self).contains("secret"))
        #expect(!String(decoding: data, as: UTF8.self).contains("https://"))
        let reattached = QueueTestTransport(active: Set(pending.map(\.id)))
        let restored = try controller(at: journal, transport: reattached, storage: storage, serverID: server)
        try await restored.start()
        #expect(await restored.snapshot().count == 12)
        #expect(await reattached.requests.isEmpty)
    }

    @Test func completedReceiptSurvivesRelaunchAndCommitsBeforeAcknowledgement() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = root.appendingPathComponent("queue.json")
        let server = UUID(), storage = QueueTestStorage(), firstTransport = QueueTestTransport()
        let original = try controller(at: journal, transport: firstTransport, storage: storage, serverID: server)
        try await original.enqueue(songs(["a"]), serverID: server, owner: .track)
        let id = try #require(await original.snapshot().first?.id)
        let transport = QueueTestTransport(receipts: [.init(jobID: id, statusCode: 200, mimeType: "audio/flac", expectedBytes: 10)])
        let restored = try controller(at: journal, transport: transport, storage: storage, serverID: server)
        try await restored.start()
        try await wait { await transport.acknowledged.contains(id) }
        #expect(await storage.saved == ["a"])
        #expect(await restored.snapshot().isEmpty)
        #expect(await transport.requests.isEmpty)
    }

    @Test func failureStaysVisibleAndRetryIgnoresLateEventsFromOldTransfer() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = UUID(), transport = QueueTestTransport(), storage = QueueTestStorage()
        let queue = try controller(at: root.appendingPathComponent("queue.json"), transport: transport, storage: storage, serverID: server)
        try await queue.enqueue(songs(["a"]), serverID: server, owner: .track)
        let oldID = try #require(await queue.snapshot().first?.id)
        await transport.emit(.failed(oldID, .serverUnreachable))
        try await wait { await queue.snapshot().first?.status == .failed }
        try await queue.retry(songID: "a", serverID: server)
        let freshID = try #require(await queue.snapshot().first?.id)
        #expect(freshID != oldID)
        await transport.emit(.completed(.init(jobID: oldID, statusCode: 200, mimeType: "audio/flac", expectedBytes: 10)))
        await transport.emit(.completed(.init(jobID: freshID, statusCode: 200, mimeType: "audio/flac", expectedBytes: 10)))
        try await wait { await queue.snapshot().isEmpty }
        #expect(await storage.saved == ["a"])
    }

    @Test func cancellationWaitsForCommitAndPreventsLateResurrection() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = UUID(), transport = QueueTestTransport(), storage = QueueTestStorage()
        await storage.configure(block: true)
        let queue = try controller(at: root.appendingPathComponent("queue.json"), transport: transport, storage: storage, serverID: server)
        try await queue.enqueue(songs(["a"]), serverID: server, owner: .track)
        let id = try #require(await queue.snapshot().first?.id)
        await transport.emit(.completed(.init(jobID: id, statusCode: 200, mimeType: "audio/flac", expectedBytes: 10)))
        try await wait { await storage.isCommitting }
        let cancel = Task { try await queue.cancelAll() }
        try await wait { await queue.snapshot().isEmpty }
        await storage.release()
        try await cancel.value
        #expect(await storage.saved.isEmpty)
        #expect(await transport.cancelled.contains(id))
    }

    @Test func anotherOwnerKeepsASharedPendingTrack() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = UUID(), transport = QueueTestTransport(), storage = QueueTestStorage()
        let queue = try controller(at: root.appendingPathComponent("queue.json"), transport: transport, storage: storage, serverID: server)
        let track = try songs(["a"])
        try await queue.enqueue(track, serverID: server, owner: .playlist("p"))
        try await queue.enqueue(track, serverID: server, owner: .album("a"))
        try await queue.removeOwner(.playlist("p"), serverID: server)
        #expect(await queue.snapshot().count == 1)
        #expect(await transport.cancelled.isEmpty)
        try await queue.enqueue(track, serverID: server, owner: .track)
        try await queue.removeOwner(.album("a"), serverID: server)
        #expect(await queue.snapshot().first?.owners == [.track])
        #expect(await transport.requests.count == 1)
        try await queue.cancel(songID: "a", serverID: server)
        #expect(await queue.snapshot().isEmpty)
    }

    @Test func wrongServerCredentialsNeverStartATransfer() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = UUID(), transport = QueueTestTransport(), storage = QueueTestStorage()
        let queue = try controller(at: root.appendingPathComponent("queue.json"), transport: transport, storage: storage,
                                   serverID: server, connectionID: UUID())
        try await queue.enqueue(songs(["a"]), serverID: server, owner: .track)
        #expect(await transport.requests.isEmpty)
        #expect(await queue.snapshot().first?.status == .queued)
    }

    @Test func removalDuringPreparationCannotRecreateACollection() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = UUID(), transport = QueueTestTransport(), storage = QueueTestStorage()
        let queue = try controller(at: root.appendingPathComponent("queue.json"), transport: transport, storage: storage, serverID: server)
        let registry = DownloadIntentRegistry()
        let key = DownloadIntentRegistry.Key(serverID: server, owner: .playlist("p"))
        let intent = try registry.capture(key)
        await storage.configureLookup()
        let tracks = try songs(["a"])
        let preparing = Task {
            try await queue.enqueue(tracks, serverID: server, owner: .playlist("p"), isCurrent: { intent.isCurrent })
        }
        try await wait { await storage.isLookingUp }
        registry.beginRemoval(key)
        try await queue.removeOwner(.playlist("p"), serverID: server)
        #expect(throws: CancellationError.self) { try registry.capture(key) }
        registry.endRemoval(key)
        await storage.releaseLookup()
        do { try await preparing.value; Issue.record("A removed collection was recreated") }
        catch is CancellationError { }
        #expect(await queue.snapshot().isEmpty)
        #expect(await transport.requests.isEmpty)
        #expect(try registry.capture(key).isCurrent)
        #expect(!intent.isCurrent)
    }

    @Test func journalWriteFailureRollsBackEnqueueAndPreservesACancelledJob() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = root.appendingPathComponent("queue.json")
        let server = UUID(), transport = QueueTestTransport(), storage = QueueTestStorage()
        let queue = try controller(at: journal, transport: transport, storage: storage, serverID: server)
        try await queue.start()
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
        do { try await queue.enqueue(songs(["a"]), serverID: server, owner: .track); Issue.record("Expected write failure") }
        catch { }
        #expect(await queue.snapshot().isEmpty)
        #expect(await transport.requests.isEmpty)
        try FileManager.default.removeItem(at: journal)
        try await queue.enqueue(songs(["a"]), serverID: server, owner: .track)
        let id = try #require(await queue.snapshot().first?.id)
        try FileManager.default.removeItem(at: journal)
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
        do { try await queue.cancelAll(); Issue.record("Expected write failure") }
        catch { }
        #expect(await queue.snapshot().first?.id == id)
        #expect(await transport.cancelled.isEmpty)
    }

    @Test func failedCommitKeepsReceiptAndARecoverableError() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = root.appendingPathComponent("queue.json")
        let server = UUID(), transport = QueueTestTransport(), storage = QueueTestStorage()
        await storage.configure(fail: true)
        let queue = try controller(at: journal, transport: transport, storage: storage, serverID: server)
        try await queue.enqueue(songs(["a"]), serverID: server, owner: .track)
        let id = try #require(await queue.snapshot().first?.id)
        await transport.emit(.completed(.init(jobID: id, statusCode: 200, mimeType: "audio/flac", expectedBytes: 10)))
        try await wait { await queue.snapshot().first?.status == .failed }
        #expect(await storage.saved.isEmpty)
        #expect(await transport.acknowledged.isEmpty)
        #expect(try JSONDecoder().decode([QueuedDownload].self, from: Data(contentsOf: journal)).first?.status == .failed)
    }
}
