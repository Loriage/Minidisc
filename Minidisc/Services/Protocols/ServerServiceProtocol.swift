import Foundation

protocol ServerServiceProtocol: AnyObject, Sendable {
    var state: ServerState { get }

    func addServer(
        displayName: String,
        baseURL: String,
        username: String,
        password: String,
        customHeaders: [String: String]
    ) async throws

    func removeServer(id: UUID) async throws

    func setActiveServer(id: UUID) async throws

    func updateCustomHeaders(_ headers: [String: String], forServer id: UUID) async throws

    func updateServer(
        id: UUID,
        displayName: String,
        baseURL: String,
        username: String,
        password: String,
        customHeaders: [String: String]
    ) async throws

    /// Stores or clears the AudioMuse-AI endpoint for a server. `nil` URL disconnects the
    /// integration and drops the token from Keychain.
    func setAudioMuseConfig(serverId: UUID, urlString: String?, token: String?) async throws

    func testConnection() async throws

    /// Tests connectivity to the given parameters without persisting anything.
    /// Runs ping then getUser for full credential validation.
    /// Throws `ConnectionTestError` for differentiated UI error handling.
    func testConnection(
        url: String,
        username: String,
        password: String,
        customHeaders: [String: String]
    ) async throws

    /// Returns the current process-local connection version without reading Keychain.
    /// Long-lived clients use this as their cache key.
    func activeConnectionVersion() async -> ServerConnection.Version?

    /// Returns one process-local snapshot whose metadata and authorization share a revision.
    func activeConnection() async throws -> ServerConnection

    /// Restores servers and activeServer from SwiftData + Keychain on app launch.
    /// Sets state.isLoadingPersistedState = false when complete (even on failure).
    func loadPersistedState() async
}
