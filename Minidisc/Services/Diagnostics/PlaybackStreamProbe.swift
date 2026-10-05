import Foundation
import Synchronization

nonisolated enum PlaybackStreamProbe {
    struct Result: Sendable, Equatable {
        enum Content: String, Sendable { case audio, json, xml, html, binary, other, missing }
        enum Payload: String, Sendable { case audioSignature, markup, json, unknown, empty }
        var status: Int?
        var content: Content = .missing
        var contentLength: Int64?
        var byteRange: String?
        var acceptsByteRanges = false
        var bytesRead = 0
        var payload: Payload = .empty
        var responseSeconds: Double?
        var firstByteSeconds: Double?
        var elapsed: Double = 0
        var redirects = 0
        var crossOriginRedirectBlocked = false
        var failure: PlaybackDiagnosticFailure?

        var isUnexpected: Bool {
            if failure?.kind == .cancelled { return false }
            return failure != nil || (status.map { !(200..<300).contains($0) } ?? false)
                || bytesRead == 0 || payload == .markup || payload == .json
                || content == .html || content == .json || content == .xml || crossOriginRedirectBlocked
        }

        mutating func observe(_ response: HTTPURLResponse) {
            status = response.statusCode
            let type = response.mimeType?.lowercased() ?? ""
            content = switch type {
            case let type where type.hasPrefix("audio/"): .audio
            case "application/json", "text/json": .json
            case "application/xml", "text/xml": .xml
            case "text/html": .html
            case "application/octet-stream": .binary
            case "": .missing
            default: .other
            }
            contentLength = response.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init).flatMap { $0 >= 0 ? $0 : nil }
            acceptsByteRanges = response.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() == "bytes"
            if let range = response.value(forHTTPHeaderField: "Content-Range"), range.count < 80,
               range.range(of: #"^bytes [0-9]+-[0-9]+/([0-9]+|\*)$"#, options: .regularExpression) != nil {
                byteRange = range
            }
        }

        mutating func observePrefix(_ bytes: [UInt8]) {
            guard !bytes.isEmpty else { payload = .empty; return }
            let trimmed = bytes.drop(while: { [9, 10, 13, 32].contains($0) })
            if trimmed.first == 60 { payload = .markup }
            else if trimmed.first == 123 || trimmed.first == 91 { payload = .json }
            else if bytes.starts(with: Array("fLaC".utf8)) || bytes.starts(with: Array("ID3".utf8))
                || bytes.starts(with: Array("OggS".utf8)) || bytes.starts(with: Array("RIFF".utf8))
                || (bytes.count >= 8 && Array(bytes[4..<8]) == Array("ftyp".utf8))
                || (bytes.count >= 2 && bytes[0] == 0xff && bytes[1] & 0xe0 == 0xe0) {
                payload = .audioSignature
            } else { payload = .unknown }
        }

        var description: String {
            func seconds(_ value: Double?) -> String { value.map { String(format: "%.3f", $0) } ?? "unknown" }
            return "http=\(status.map(String.init) ?? "unknown") content=\(content.rawValue) length=\(contentLength.map(String.init) ?? "unknown") content-range=\(byteRange ?? "none") accepts-ranges=\(acceptsByteRanges) bytes-read=\(bytesRead) payload=\(payload.rawValue) response=\(seconds(responseSeconds))s first-byte=\(seconds(firstByteSeconds))s elapsed=\(seconds(elapsed))s redirects=\(redirects) cross-origin-blocked=\(crossOriginRedirectBlocked) failure={\(failure?.description ?? "none")}"
        }
    }

    static func run(url: URL, headers: [String: String], configuration: URLSessionConfiguration = .ephemeral) async -> Result {
        let redirects = RedirectGuard(origin: url)
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 8
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration, delegate: redirects, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return await withTaskCancellationHandler {
            let started = ProcessInfo.processInfo.systemUptime
            var result = Result()
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
            var prefix: [UInt8] = []
            do {
                try Task.checkCancellation()
                let (bytes, response) = try await session.bytes(for: request)
                result.responseSeconds = ProcessInfo.processInfo.systemUptime - started
                if let http = response as? HTTPURLResponse { result.observe(http) }
                // Cancel immediately after a small prefix, even if the server ignores Range.
                for try await byte in bytes {
                    try Task.checkCancellation()
                    if result.bytesRead == 0 { result.firstByteSeconds = ProcessInfo.processInfo.systemUptime - started }
                    result.bytesRead += 1
                    if prefix.count < 32 { prefix.append(byte) }
                    if result.bytesRead >= 1_024 { break }
                }
            } catch { result.failure = PlaybackDiagnosticFailure(error) }
            result.observePrefix(prefix)
            result.elapsed = ProcessInfo.processInfo.systemUptime - started
            result.redirects = redirects.count
            result.crossOriginRedirectBlocked = redirects.blocked
            return result
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let origin: URL
        private let state = Mutex((count: 0, blocked: false))
        var count: Int { state.withLock { $0.count } }
        var blocked: Bool { state.withLock { $0.blocked } }
        init(origin: URL) { self.origin = origin }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            let allowed = request.url.map { ServerConnection.isSameOrigin(origin, $0) } ?? false
            state.withLock { $0.count += 1; $0.blocked = $0.blocked || !allowed }
            completionHandler(allowed ? request : nil)
        }
    }
}
