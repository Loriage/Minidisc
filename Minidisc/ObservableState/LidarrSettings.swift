import Foundation
import Observation
import OSLog

/// Secret part of a Lidarr connection: the API key and any reverse-proxy headers. Stored in the
/// Keychain as one record, never in UserDefaults.
nonisolated struct LidarrCredentials: Codable, Sendable {
    let apiKey: String
    var headers: [String: String] = [:]
}

/// Stores the connection to a Lidarr instance: the base URL in UserDefaults, and the API key plus
/// any custom headers in the Keychain. Global rather than per-server, because Lidarr is a separate
/// service from the music server.
@Observable
@MainActor
final class LidarrSettings {
    @ObservationIgnored private let keychain: any KeychainServiceProtocol
    @ObservationIgnored private let defaults: UserDefaults

    @ObservationIgnored private var _baseURL: String
    /// True when both a base URL and stored credentials are present. Drives the Settings status.
    private(set) var isConnected: Bool = false

    var baseURL: String {
        access(keyPath: \.baseURL)
        return _baseURL
    }

    private static let baseURLKey = "app.minidisc.lidarr.baseURL"
    private static let credentialsKeychainKey = "app.minidisc.lidarr.credentials"

    init(keychain: any KeychainServiceProtocol, defaults: UserDefaults = .standard) {
        self.keychain = keychain
        self.defaults = defaults
        self._baseURL = defaults.string(forKey: Self.baseURLKey) ?? ""
    }

    /// Reads back whether credentials are present, so `isConnected` is correct after a cold start.
    func loadPersistedState() async {
        let hasCreds = (try? await keychain.retrieve(LidarrCredentials.self, forKey: Self.credentialsKeychainKey)) != nil
        withMutation(keyPath: \.isConnected) {
            isConnected = hasCreds && !_baseURL.isEmpty
        }
        Logger.integrations.debug("Lidarr state loaded, connected=\(self.isConnected, privacy: .public)")
    }

    /// The stored credentials, so the Settings screen can pre-fill the fields for editing.
    func currentCredentials() async -> LidarrCredentials? {
        let stored = try? await keychain.retrieve(LidarrCredentials.self, forKey: Self.credentialsKeychainKey)
        return stored ?? nil
    }

    /// Persists the connection after the Settings screen has tested it.
    func connect(baseURL: String, apiKey: String, headers: [String: String]) async throws {
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        try await keychain.store(LidarrCredentials(apiKey: apiKey, headers: headers), forKey: Self.credentialsKeychainKey)
        defaults.set(trimmedURL, forKey: Self.baseURLKey)
        withMutation(keyPath: \.baseURL) { _baseURL = trimmedURL }
        withMutation(keyPath: \.isConnected) { isConnected = true }
    }

    func disconnect() async {
        try? await keychain.delete(forKey: Self.credentialsKeychainKey)
        defaults.removeObject(forKey: Self.baseURLKey)
        withMutation(keyPath: \.baseURL) { _baseURL = "" }
        withMutation(keyPath: \.isConnected) { isConnected = false }
    }

    /// Builds a client from the stored connection, or nil when nothing is configured.
    func makeClient() async -> LidarrClient? {
        guard !_baseURL.isEmpty, let creds = await currentCredentials() else { return nil }
        return LidarrClient(urlString: _baseURL, apiKey: creds.apiKey, headers: creds.headers)
    }
}
