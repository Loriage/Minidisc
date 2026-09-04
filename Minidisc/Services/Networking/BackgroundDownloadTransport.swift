import Foundation
import Synchronization
import UIKit

nonisolated struct CompletedDownload: Codable, Sendable {
    let jobID: UUID
    let statusCode: Int
    let mimeType: String?
    let expectedBytes: Int64

    func response() -> HTTPURLResponse {
        var headers: [String: String] = [:]
        if let mimeType { headers["Content-Type"] = mimeType }
        if expectedBytes > 0 { headers["Content-Length"] = String(expectedBytes) }
        return HTTPURLResponse(url: URL(string: "https://download.invalid")!, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: headers)!
    }
}

nonisolated enum DownloadTransportEvent: Sendable {
    case progress(UUID, received: Int64, expected: Int64)
    case waiting(UUID)
    case completed(CompletedDownload)
    case failed(UUID, UserFacingError)
}

nonisolated protocol DownloadTransport: Sendable {
    var events: AsyncStream<DownloadTransportEvent> { get }
    func activeJobIDs() async -> Set<UUID>
    func start(jobID: UUID, request: URLRequest) async
    func cancel(jobID: UUID) async
    func completedTransfers() async -> [CompletedDownload]
    func fileURL(jobID: UUID) async -> URL
    func acknowledge(jobID: UUID) async
}

/// One system-owned session. Completed payloads and receipts are durable before the delegate
/// returns, so relaunch does not depend on a SwiftUI scene or an in-memory continuation.
actor BackgroundDownloadTransport: DownloadTransport {
    static let identifier = "com.nohitdev.minidisc.audio-downloads"
    static let shared = BackgroundDownloadTransport(identifier: identifier)
    nonisolated let events: AsyncStream<DownloadTransportEvent>
    private let session: URLSession
    private let inbox: URL

    init(identifier: String? = nil, inbox: URL = URL.applicationSupportDirectory.appendingPathComponent("minidisc-download-inbox", isDirectory: true)) {
        self.inbox = inbox
        let channel = AsyncStream<DownloadTransportEvent>.makeStream()
        events = channel.stream
        let delegate = DownloadSessionDelegate(inbox: inbox, continuation: channel.continuation)
        let configuration = identifier.map(URLSessionConfiguration.background(withIdentifier:)) ?? .default
        configuration.waitsForConnectivity = true
        configuration.httpMaximumConnectionsPerHost = 3
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        if identifier != nil {
            configuration.isDiscretionary = false
            configuration.sessionSendsLaunchEvents = true
        }
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "Minidisc downloads"
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
    }

    func activeJobIDs() async -> Set<UUID> {
        Set(await session.allTasks.compactMap { $0.taskDescription.flatMap(UUID.init(uuidString:)) })
    }

    func start(jobID: UUID, request: URLRequest) {
        let task = session.downloadTask(with: request)
        task.taskDescription = jobID.uuidString
        task.resume()
    }

    func cancel(jobID: UUID) async {
        for task in await session.allTasks where task.taskDescription == jobID.uuidString { task.cancel() }
    }

    func completedTransfers() -> [CompletedDownload] {
        let files = (try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap {
            guard let data = try? Data(contentsOf: $0) else { return nil }
            return try? JSONDecoder().decode(CompletedDownload.self, from: data)
        }
    }

    func fileURL(jobID: UUID) -> URL { inbox.appendingPathComponent(jobID.uuidString + ".audio") }

    func acknowledge(jobID: UUID) {
        try? FileManager.default.removeItem(at: fileURL(jobID: jobID))
        try? FileManager.default.removeItem(at: inbox.appendingPathComponent(jobID.uuidString + ".json"))
    }
}

private nonisolated final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    private let inbox: URL
    private let continuation: AsyncStream<DownloadTransportEvent>.Continuation
    private let lastProgress = Mutex<[UUID: Date]>([:])

    init(inbox: URL, continuation: AsyncStream<DownloadTransportEvent>.Continuation) {
        self.inbox = inbox
        self.continuation = continuation
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription.flatMap(UUID.init(uuidString:)) else { return }
        do {
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            let target = inbox.appendingPathComponent(id.uuidString + ".audio")
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.moveItem(at: location, to: target)
            let receipt = CompletedDownload(jobID: id, statusCode: (downloadTask.response as? HTTPURLResponse)?.statusCode ?? -1,
                                            mimeType: downloadTask.response?.mimeType,
                                            expectedBytes: downloadTask.response?.expectedContentLength ?? -1)
            try JSONEncoder().encode(receipt).write(to: inbox.appendingPathComponent(id.uuidString + ".json"), options: .atomic)
            continuation.yield(.completed(receipt))
        } catch { continuation.yield(.failed(id, .downloadFailed)) }
        lastProgress.withLock { _ = $0.removeValue(forKey: id) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription.flatMap(UUID.init(uuidString:)) else { return }
        let shouldPublish = lastProgress.withLock { values in
            let now = Date()
            guard values[id].map({ now.timeIntervalSince($0) >= 0.5 }) ?? true else { return false }
            values[id] = now
            return true
        }
        if shouldPublish { continuation.yield(.progress(id, received: totalBytesWritten, expected: totalBytesExpectedToWrite)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let error, let id = task.taskDescription.flatMap(UUID.init(uuidString:)) else { return }
        continuation.yield(.failed(id, UserFacingError.from(error)))
        lastProgress.withLock { _ = $0.removeValue(forKey: id) }
    }

    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        guard let id = task.taskDescription.flatMap(UUID.init(uuidString:)) else { return }
        continuation.yield(.waiting(id))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        // Every preceding completion has a durable receipt. Processing is replayable if iOS
        // suspends us while validating/remuxing/committing metadata.
        Task { @MainActor in MinidiscAppDelegate.finishDownloadEvents() }
    }
}

@MainActor
final class MinidiscAppDelegate: NSObject, UIApplicationDelegate {
    private static var completion: (() -> Void)?
    private static var eventsFinished = false

    override init() {
        super.init()
        _ = BackgroundDownloadTransport.shared
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundDownloadTransport.identifier else { completionHandler(); return }
        Self.completion = completionHandler
        _ = BackgroundDownloadTransport.shared
        if Self.eventsFinished { Self.finishDownloadEvents() }
    }

    static func finishDownloadEvents() {
        guard let handler = completion else { eventsFinished = true; return }
        completion = nil
        eventsFinished = false
        handler()
    }
}
