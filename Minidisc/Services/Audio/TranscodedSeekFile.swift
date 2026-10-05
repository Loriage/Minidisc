import Foundation
import OSLog
import SwiftSonic

/// Owns a completed transcode only for the lifetime of its playback source.
nonisolated final class TranscodedSeekFile: Sendable {
    let url: URL

    init(url: URL) { self.url = url }

    deinit { try? FileManager.default.removeItem(at: url) }

    static func prepare(_ source: MediaSource) async throws -> MediaSource {
        guard source.needsCompleteFileForSeeking else { return source }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        let session = URLSession(configuration: config, delegate: SameOriginRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = PlayerService.cacheDownloadRequest(
            url: source.url, headers: source.customHeaders, allowCellular: true
        )
        request.networkServiceType = .avStreaming
        let (temporaryURL, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SwiftSonicError.httpError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0, endpoint: "stream", serverHost: nil)
        }
        try AudioResponseValidator.validate(
            fileAt: temporaryURL, response: response, songId: "seek-buffer", logger: Logger.player
        )
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("minidisc-seek-\(UUID().uuidString).mp3")
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return .seekBuffer(TranscodedSeekFile(url: destination))
    }

    private final class SameOriginRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            guard let original = task.originalRequest?.url, let target = request.url,
                  ServerConnection.isSameOrigin(original, target) else {
                completionHandler(nil)
                return
            }
            var redirected = request
            for (key, value) in task.originalRequest?.allHTTPHeaderFields ?? [:] {
                redirected.setValue(value, forHTTPHeaderField: key)
            }
            completionHandler(redirected)
        }
    }
}
