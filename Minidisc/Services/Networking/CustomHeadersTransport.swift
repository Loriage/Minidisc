import Foundation
import OSLog
import SwiftSonic

/// Injects validated secret headers into SwiftSonic requests; never log their values.
/// AVPlayer and background downloads inject headers separately.
/// Both request and resource timeouts are bounded to avoid hung metadata lookups.
struct CustomHeadersTransport: HTTPTransport, Sendable {
    private let base: any HTTPTransport
    private let headers: [String: String]

    init(headers: [String: String], timeout: TimeInterval = 30) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        // Session-level injection ensures headers reach Cloudflare Access on every
        // request path, including any internal URLSession hop before SwiftSonic
        // intercepts the redirect.
        config.httpAdditionalHeaders = headers
        self.base = URLSessionTransport(configuration: config)
        self.headers = headers
    }

    init(base: any HTTPTransport, headers: [String: String]) {
        self.base = base
        self.headers = headers
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var enriched = request
        let hadAuthorization = enriched.value(forHTTPHeaderField: "Authorization") != nil
        let authCollision = headers.keys.contains { $0.caseInsensitiveCompare("Authorization") == .orderedSame }
        for (key, value) in headers {
            enriched.setValue(value, forHTTPHeaderField: key)
        }
        let cfId = headers.first(where: { $0.key.caseInsensitiveCompare("CF-Access-Client-Id") == .orderedSame })?.value
        let cfSecret = headers.first(where: { $0.key.caseInsensitiveCompare("CF-Access-Client-Secret") == .orderedSame })?.value
        Logger.httpTransport.debug("CustomHeadersTransport: injected_keys=\(Array(headers.keys).sorted(), privacy: .private) had_auth=\(hadAuthorization, privacy: .public) auth_collision=\(authCollision, privacy: .public)")
        Logger.httpTransport.debug("CustomHeadersTransport CF headers: id=\(cfId.map { $0.isEmpty ? "EMPTY" : "SET" } ?? "ABSENT", privacy: .public) secret=\(cfSecret.map { $0.isEmpty ? "EMPTY" : "SET" } ?? "ABSENT", privacy: .public)")
        return try await base.data(for: enriched)
    }
}
