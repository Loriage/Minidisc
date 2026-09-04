import Foundation
import SwiftSonic

/// A coherent, versioned snapshot of the active server and its authorization.
///
/// The value is created by `ServerService` so a request never combines metadata from one
/// configuration revision with credentials from another. It must remain process-local because it
/// contains Keychain-backed secrets.
nonisolated struct ServerConnection: Sendable {
    struct Version: Sendable, Hashable, CustomStringConvertible {
        let serverID: UUID
        let revision: UInt64

        var description: String {
            "server=[REDACTED] revision=\(revision)"
        }
    }

    let version: Version
    let server: ServerSnapshot
    let baseURL: URL
    let credentials: ServerCredentials

    init(
        version: Version,
        server: ServerSnapshot,
        credentials: ServerCredentials
    ) throws {
        guard version.serverID == server.id else {
            throw MinidiscError.serverNotConfigured
        }
        guard let baseURL = URL(string: server.baseURL),
              let scheme = baseURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              baseURL.host != nil else {
            throw MinidiscError.invalidServerURL(server.baseURL)
        }

        self.version = version
        self.server = server
        self.baseURL = baseURL
        self.credentials = credentials
    }

    func makeSwiftSonicClient(
        requestTimeout: TimeInterval = 30,
        retryPolicy: RetryPolicy = .default
    ) -> SwiftSonicClient {
        SwiftSonicClient(
            configuration: ServerConfiguration(
                serverURL: baseURL,
                username: server.username,
                password: credentials.password,
                requestTimeout: requestTimeout
            ),
            transport: CustomHeadersTransport(headers: credentials.customHeaders),
            retryPolicy: retryPolicy,
            logSubsystem: "app.minidisc.server"
        )
    }

    /// Returns server authorization only for the configured origin. This prevents reverse-proxy
    /// credentials from leaking to third-party radio or artwork hosts.
    func authorizationHeaders(for url: URL) -> [String: String] {
        Self.isSameOrigin(url, baseURL) ? credentials.customHeaders : [:]
    }

    static func isSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let lhsScheme = lhs.scheme?.lowercased(),
              let rhsScheme = rhs.scheme?.lowercased(),
              let lhsHost = lhs.host?.lowercased(),
              let rhsHost = rhs.host?.lowercased() else { return false }

        func effectivePort(_ url: URL, scheme: String) -> Int? {
            url.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : nil)
        }

        return lhsScheme == rhsScheme
            && lhsHost == rhsHost
            && effectivePort(lhs, scheme: lhsScheme) == effectivePort(rhs, scheme: rhsScheme)
    }
}

extension ServerConnection: CustomStringConvertible {
    var description: String {
        "ServerConnection(\(version), endpoint=[REDACTED], credentials=[REDACTED])"
    }
}

extension ServerConnection: CustomDebugStringConvertible {
    var debugDescription: String { description }
}
