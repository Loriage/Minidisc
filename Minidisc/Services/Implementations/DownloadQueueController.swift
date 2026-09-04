import Foundation
import SwiftSonic

nonisolated enum DownloadOwner: Hashable, Sendable, Codable {
    case track
    case album(String)
    case playlist(String)
}

nonisolated struct QueuedDownload: Codable, Sendable, Identifiable {
    let id: UUID
    let song: Song
    let serverID: UUID
    var owners: Set<DownloadOwner>
    var status: DownloadTransferStatus = .queued
    var received: Int64 = 0
    var expected: Int64 = -1
    var error: UserFacingError?

    var progress: DownloadProgress {
        DownloadProgress(songId: song.id, serverId: serverID,
                         progress: expected > 0 ? min(1, Double(received) / Double(expected)) : 0,
                         totalBytes: expected > 0 ? expected : nil, receivedBytes: received,
                         title: song.title, status: status, error: error)
    }
}

/// Owns durable requests, not media files. Transport and commit seams make relaunch, cancellation
/// and storage failures testable without a running media server or an iOS background scheduler.
actor DownloadQueueController {
    typealias ConnectionProvider = @Sendable (UUID) async throws -> ServerConnection
    typealias LocalLookup = @Sendable (String, UUID) async -> Bool
    typealias Commit = @Sendable (Song, UUID, URL, HTTPURLResponse) async throws -> Void
    private let journalURL: URL
    private let transport: any DownloadTransport
    private let connection: ConnectionProvider
    private let isDownloaded: LocalLookup
    private let commit: Commit
    private let onProgress: @Sendable ([DownloadProgress]) async -> Void
    private let diagnostics: PlaybackDiagnostics?
    private var jobs: [UUID: QueuedDownload] = [:]
    private var waiters: [UUID: [UUID: CheckedContinuation<Void, any Error>]] = [:]
    private var commits: [UUID: Task<Void, Never>] = [:]
    private var starting: Set<UUID> = []
    private var eventsTask: Task<Void, Never>?
    private var startupTask: Task<Void, any Error>?
    private var generation: UInt64 = 0

    init(journalURL: URL, transport: any DownloadTransport, connection: @escaping ConnectionProvider,
         isDownloaded: @escaping LocalLookup, commit: @escaping Commit,
         onProgress: @escaping @Sendable ([DownloadProgress]) async -> Void,
         diagnostics: PlaybackDiagnostics? = nil) {
        self.journalURL = journalURL
        self.transport = transport
        self.connection = connection
        self.isDownloaded = isDownloaded
        self.commit = commit
        self.onProgress = onProgress
        self.diagnostics = diagnostics
    }

    deinit { eventsTask?.cancel() }

    func start() async throws {
        if let startupTask { try await startupTask.value; return }
        let task = Task { try await self.restore() }
        startupTask = task
        do { try await task.value }
        catch { startupTask = nil; throw error }
    }

    private func restore() async throws {
        if FileManager.default.fileExists(atPath: journalURL.path) {
            let saved = try JSONDecoder().decode([QueuedDownload].self, from: Data(contentsOf: journalURL))
            jobs = Dictionary(saved.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        let active = await transport.activeJobIDs()
        for id in active where jobs[id] == nil { await transport.cancel(jobID: id) }
        for id in jobs.keys {
            if jobs[id]?.status != .failed { jobs[id]?.status = active.contains(id) ? .downloading : .queued }
        }
        let receipts = await transport.completedTransfers()
        for receipt in receipts {
            guard jobs[receipt.jobID] != nil else { await transport.acknowledge(jobID: receipt.jobID); continue }
            if jobs[receipt.jobID]?.status != .failed { await receive(.completed(receipt)) }
        }
        eventsTask = Task { [weak self, transport] in
            for await event in transport.events {
                guard !Task.isCancelled else { break }
                await self?.receive(event)
            }
        }
        await publish()
        await schedulePending()
    }

    func enqueue(_ songs: [Song], serverID: UUID, owner: DownloadOwner,
                 isCurrent: @Sendable () -> Bool = { true }) async throws {
        try await start()
        let epoch = generation
        var candidates: [Song] = []
        for song in songs {
            try Task.checkCancellation()
            let local = await isDownloaded(song.id, serverID)
            guard epoch == generation else { throw CancellationError() }
            if !local { candidates.append(song) }
        }
        try Task.checkCancellation()
        guard isCurrent(), epoch == generation else { throw CancellationError() }
        let previous = jobs
        var retired: [UUID] = []
        for song in candidates {
            if let id = id(for: song.id, serverID: serverID), var job = jobs[id] {
                job.owners.insert(owner)
                if job.status == .failed {
                    jobs.removeValue(forKey: id)
                    retired.append(id)
                    let replacement = QueuedDownload(id: UUID(), song: song, serverID: serverID, owners: job.owners)
                    jobs[replacement.id] = replacement
                } else { jobs[id] = job }
            } else {
                let job = QueuedDownload(id: UUID(), song: song, serverID: serverID, owners: [owner])
                jobs[job.id] = job
            }
        }
        // All members become durable together. A failed journal write must not leave ghost jobs
        // in memory that a later unrelated request could accidentally schedule.
        do { try persist() }
        catch { jobs = previous; throw error }
        for id in retired { await transport.acknowledge(jobID: id) }
        await publish()
        await schedulePending()
    }

    func resumePending() async throws {
        try await start()
        await schedulePending()
    }

    func wait(songID: String, serverID: UUID) async throws {
        try await start()
        try Task.checkCancellation()
        if await isDownloaded(songID, serverID) { return }
        guard let id = id(for: songID, serverID: serverID), let job = jobs[id] else {
            if await isDownloaded(songID, serverID) { return }
            throw CancellationError()
        }
        if job.status == .failed { throw job.error ?? .downloadFailed }
        let waiter = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[id, default: [:]][waiter] = continuation
                if Task.isCancelled { Task { await self.cancelWaiter(jobID: id, waiterID: waiter) } }
            }
        } onCancel: {
            Task { await self.cancelWaiter(jobID: id, waiterID: waiter) }
        }
    }

    private func cancelWaiter(jobID: UUID, waiterID: UUID) async {
        waiters[jobID]?.removeValue(forKey: waiterID)?.resume(throwing: CancellationError())
        if waiters[jobID]?.isEmpty != false { try? await cancel(jobID: jobID) }
    }

    func retry(songID: String, serverID: UUID) async throws {
        try await start()
        guard let id = id(for: songID, serverID: serverID), let old = jobs[id], old.status == .failed else { return }
        let replacement = QueuedDownload(id: UUID(), song: old.song, serverID: serverID, owners: old.owners)
        jobs.removeValue(forKey: id)
        jobs[replacement.id] = replacement
        do { try persist() }
        catch { jobs.removeValue(forKey: replacement.id); jobs[id] = old; throw error }
        await transport.acknowledge(jobID: id)
        await schedulePending()
        await publish()
    }

    func cancel(songID: String, serverID: UUID) async throws {
        try await start()
        guard let id = id(for: songID, serverID: serverID) else { return }
        try await cancel(jobID: id)
    }

    func removeOwner(_ owner: DownloadOwner, serverID: UUID) async throws {
        try await start()
        let previous = jobs
        let ids = jobs.values.filter { $0.serverID == serverID && $0.owners.contains(owner) }.map(\.id)
        var retired: [UUID] = []
        for id in ids {
            jobs[id]?.owners.remove(owner)
            if jobs[id]?.owners.isEmpty == true { jobs.removeValue(forKey: id); retired.append(id) }
        }
        do { try persist() }
        catch { jobs = previous; throw error }
        for id in retired { await retire(id) }
        await publish()
    }

    func cancelAll() async throws {
        try await start()
        generation &+= 1
        let previous = jobs
        jobs = [:]
        do { try persist() }
        catch { jobs = previous; throw error }
        for id in previous.keys { await retire(id) }
        await publish()
    }

    private func cancel(jobID id: UUID) async throws {
        guard let previous = jobs.removeValue(forKey: id) else { return }
        do { try persist() }
        catch { jobs[id] = previous; throw error }
        await retire(id)
        await publish()
    }

    private func retire(_ id: UUID) async {
        finishWaiters(id, result: .failure(CancellationError()))
        let task = commits[id]
        task?.cancel()
        await transport.cancel(jobID: id)
        await task?.value
        commits.removeValue(forKey: id)
        await transport.acknowledge(jobID: id)
    }

    func snapshot() -> [QueuedDownload] { jobs.values.sorted { $0.song.title < $1.song.title } }

    private func schedulePending() async {
        for id in Array(jobs.keys) {
            guard let job = jobs[id], job.status == .queued, starting.insert(id).inserted else { continue }
            do {
                let connection = try await connection(job.serverID)
                guard jobs[id]?.status == .queued else { starting.remove(id); continue }
                guard connection.version.serverID == job.serverID else {
                    starting.remove(id)
                    continue
                }
                guard let url = connection.makeSwiftSonicClient().streamURL(id: job.song.id) else {
                    throw UserFacingError.contentRemoved
                }
                var request = URLRequest(url: url)
                for (name, value) in connection.authorizationHeaders(for: url) { request.setValue(value, forHTTPHeaderField: name) }
                jobs[id]?.status = .downloading
                try persist()
                await transport.start(jobID: id, request: request)
            } catch {
                // No active connection (or an inactive server) keeps the durable request queued.
                // Explicit transfer/commit failures are handled separately and remain retryable.
                guard jobs[id] != nil else { starting.remove(id); continue }
                if let error = error as? MinidiscError {
                    switch error {
                    case .serverNotConfigured, .serverNotFound: jobs[id]?.status = .queued
                    default: fail(id, error: UserFacingError.from(error))
                    }
                } else if UserFacingError.isCancellation(error) {
                    jobs[id]?.status = .queued
                } else { fail(id, error: UserFacingError.from(error)) }
            }
            starting.remove(id)
        }
        await publish()
    }

    private func receive(_ event: DownloadTransportEvent) async {
        switch event {
        case .progress(let id, let received, let expected):
            guard jobs[id] != nil, jobs[id]?.status != .failed, commits[id] == nil else { return }
            jobs[id]?.received = received
            jobs[id]?.expected = expected
            jobs[id]?.status = .downloading
        case .waiting(let id):
            guard jobs[id] != nil, jobs[id]?.status != .failed, commits[id] == nil else { return }
            jobs[id]?.status = .waiting
        case .failed(let id, let error):
            guard jobs[id] != nil, commits[id] == nil else { return }
            fail(id, error: error)
        case .completed(let receipt):
            let id = receipt.jobID
            guard let job = jobs[id] else { await transport.acknowledge(jobID: id); return }
            guard commits[id] == nil else { return }
            jobs[id]?.status = .processing
            commits[id] = Task { [commit, transport] in
                do {
                    let file = await transport.fileURL(jobID: id)
                    try Task.checkCancellation()
                    try await commit(job.song, job.serverID, file, receipt.response())
                    try Task.checkCancellation()
                    await self.commitFinished(id)
                } catch {
                    if self.jobs[id] != nil { self.fail(id, error: UserFacingError.from(error)) }
                    self.commits.removeValue(forKey: id)
                    await self.publish()
                }
            }
        }
        await publish()
    }

    private func commitFinished(_ id: UUID) async {
        guard let previous = jobs.removeValue(forKey: id) else { return }
        do {
            try persist()
            await transport.acknowledge(jobID: id)
            diagnostics?.recordDownloadOutcome(succeeded: true)
            finishWaiters(id, result: .success(()))
        } catch {
            jobs[id] = previous
            fail(id, error: .downloadFailed)
        }
        commits.removeValue(forKey: id)
        await publish()
    }

    private func fail(_ id: UUID, error: UserFacingError) {
        if let job = jobs[id], job.status != .failed { diagnostics?.recordDownloadOutcome(succeeded: false) }
        jobs[id]?.status = .failed
        jobs[id]?.error = error
        try? persist()
        finishWaiters(id, result: .failure(error))
    }

    private func finishWaiters(_ id: UUID, result: Result<Void, any Error>) {
        for waiter in (waiters.removeValue(forKey: id) ?? [:]).values { waiter.resume(with: result) }
    }

    private func id(for songID: String, serverID: UUID) -> UUID? {
        jobs.values.first { $0.song.id == songID && $0.serverID == serverID }?.id
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Array(jobs.values)).write(to: journalURL, options: .atomic)
    }

    private func publish() async { await onProgress(snapshot().map(\.progress)) }
}
