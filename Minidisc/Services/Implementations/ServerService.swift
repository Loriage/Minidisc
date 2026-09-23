import Foundation
import SwiftData
import SwiftSonic
import OSLog

actor ServerService: ServerServiceProtocol {
    nonisolated let state: ServerState

    private let keychain: any KeychainServiceProtocol
    private let modelContainer: ModelContainer
    private let audioStreamCache: any AudioStreamCacheProtocol
    private let libraryIndexStore: LibraryIndexStore?
    private let offlineFavorites: OfflineFavoritesStore?
    private let playbackDiagnostics: PlaybackDiagnostics
    private let compatibility: NavidromeCompatibility?
    private var activeServerSnapshot: ServerSnapshot?
    private var activeConnectionSnapshot: ServerConnection?
    private var connectionVersion: ServerConnection.Version?
    private var nextConnectionRevision: UInt64 = 0
    private var changingConfiguration = false
    private var configurationWaiters: [CheckedContinuation<Void, Never>] = []
    private var libraryChangeHandler: (@Sendable () async -> Void)?

    func setLibraryChangeHandler(_ handler: @escaping @Sendable () async -> Void) {
        libraryChangeHandler = handler
    }

    private func acquireConfiguration() async {
        if !changingConfiguration { changingConfiguration = true; return }
        await withCheckedContinuation { configurationWaiters.append($0) }
    }

    private func releaseConfiguration() {
        if configurationWaiters.isEmpty { changingConfiguration = false }
        else { configurationWaiters.removeFirst().resume() }
    }

    init(
        state: ServerState,
        keychain: any KeychainServiceProtocol,
        modelContainer: ModelContainer,
        audioStreamCache: any AudioStreamCacheProtocol,
        libraryIndexStore: LibraryIndexStore? = nil,
        playbackDiagnostics: PlaybackDiagnostics = PlaybackDiagnostics(),
        compatibility: NavidromeCompatibility? = nil,
        offlineFavorites: OfflineFavoritesStore? = nil
    ) {
        self.state = state
        self.keychain = keychain
        self.modelContainer = modelContainer
        self.audioStreamCache = audioStreamCache
        self.libraryIndexStore = libraryIndexStore
        self.playbackDiagnostics = playbackDiagnostics
        self.compatibility = compatibility
        self.offlineFavorites = offlineFavorites
    }

    func addServer(
        displayName: String,
        baseURL: String,
        username: String,
        password: String,
        customHeaders: [String: String]
    ) async throws {
        await acquireConfiguration()
        defer { releaseConfiguration() }
        try validateHeaders(customHeaders)

        let configId = UUID()
        let creds = ServerCredentials(password: password, customHeaders: customHeaders)
        let credKey = ServerCredentials.keychainKey(for: configId)

        // Keychain first: if SwiftData save fails below, we can roll back with a single delete.
        try await keychain.store(creds, forKey: credKey)

        do {
            let activatedServer = try await MainActor.run {
                let context = ModelContext(modelContainer)
                let existingCount = (try? context.fetchCount(FetchDescriptor<ServerConfig>())) ?? 0
                let isFirst = existingCount == 0
                let config = ServerConfig(
                    id: configId,
                    displayName: displayName,
                    baseURL: baseURL,
                    username: username,
                    isActive: isFirst
                )
                context.insert(config)
                try context.save()
                let snapshot = ServerSnapshot(from: config)
                state.servers.append(snapshot)
                if isFirst {
                    state.activeServer = snapshot
                }
                return isFirst ? snapshot : nil
            }
            if let activatedServer {
                await publishConnectionChange(server: activatedServer, credentials: creds)
            }
        } catch {
            try? await keychain.delete(forKey: credKey)
            throw error
        }
    }

    func removeServer(id: UUID) async throws {
        await acquireConfiguration()
        defer { releaseConfiguration() }
        let credKey = ServerCredentials.keychainKey(for: id)
        if activeServerSnapshot?.id == id { await libraryChangeHandler?() }

        let removedActiveServer = try await MainActor.run {
            let context = ModelContext(modelContainer)
            let descriptor = FetchDescriptor<ServerConfig>(
                predicate: #Predicate { $0.id == id }
            )
            guard let config = try context.fetch(descriptor).first else {
                throw MinidiscError.serverNotFound(id: id)
            }
            context.delete(config)
            try context.save()
            state.servers.removeAll { $0.id == id }
            if state.activeServer?.id == id {
                state.activeServer = nil
                state.isConnected = false
                return true
            }
            return false
        }

        if removedActiveServer {
            await publishConnectionRemoval()
        }

        try? await offlineFavorites?.removeServer(id)

        // Best-effort: an orphaned Keychain entry is harmless if this fails.
        try? await keychain.delete(forKey: credKey)

        // The catalogue index is a discardable cache. A purge failure must not undo
        // successful removal of the actual server configuration and credentials.
        if let libraryIndexStore {
            do {
                try await libraryIndexStore.removeServer(id)
            } catch {
                Logger.library.warning(
                    "Library index: failed to purge removed server: \(error, privacy: .public)"
                )
            }
        }
    }

    func setActiveServer(id: UUID) async throws {
        await acquireConfiguration()
        defer { releaseConfiguration() }
        if activeServerSnapshot?.id != id { await libraryChangeHandler?() }
        let (allServerIds, activeServer) = try await MainActor.run {
            let context = ModelContext(modelContainer)
            let all = try context.fetch(FetchDescriptor<ServerConfig>())
            guard let target = all.first(where: { $0.id == id }) else {
                throw MinidiscError.serverNotFound(id: id)
            }
            for config in all { config.isActive = false }
            target.isActive = true
            try context.save()
            state.activeServer = ServerSnapshot(from: target)
            state.isConnected = false
            return (all.map(\.id), ServerSnapshot(from: target))
        }

        let credentials = try? await keychain.retrieve(
            ServerCredentials.self,
            forKey: ServerCredentials.keychainKey(for: id)
        )
        await publishConnectionChange(server: activeServer, credentials: credentials)

        let othersToClean = allServerIds.filter { $0 != id }
        guard !othersToClean.isEmpty else {
            Logger.server.debug("No other servers to clean cache for at switch.")
            return
        }
        for serverId in othersToClean {
            await audioStreamCache.clearAllForServer(serverId)
        }
        Logger.server.info("Cleared cache for \(othersToClean.count) non-active server(s) at switch.")
    }

    func updateCustomHeaders(_ headers: [String: String], forServer id: UUID) async throws {
        await acquireConfiguration()
        defer { releaseConfiguration() }
        try validateHeaders(headers)
        let credKey = ServerCredentials.keychainKey(for: id)
        guard let existing = try await keychain.retrieve(ServerCredentials.self, forKey: credKey) else {
            throw MinidiscError.serverNotFound(id: id)
        }
        let updated = ServerCredentials(
            password: existing.password,
            customHeaders: headers,
            audioMuseToken: existing.audioMuseToken
        )
        try await keychain.store(updated, forKey: credKey)
        if let activeServerSnapshot, activeServerSnapshot.id == id {
            await publishConnectionChange(server: activeServerSnapshot, credentials: updated)
        }
    }

    func updateServer(
        id: UUID,
        displayName: String,
        baseURL: String,
        username: String,
        password: String,
        customHeaders: [String: String]
    ) async throws {
        await acquireConfiguration()
        defer { releaseConfiguration() }
        try validateHeaders(customHeaders)
        let selection = try await MainActor.run {
            let context = ModelContext(modelContainer)
            guard let config = try context.fetch(FetchDescriptor<ServerConfig>(predicate: #Predicate { $0.id == id })).first else {
                throw MinidiscError.serverNotFound(id: id)
            }
            return try ServerLibraryScopes.select(currentID: id, currentURL: config.baseURL,
                currentUser: config.username, saved: config.libraryScopesData, url: baseURL, user: username)
        }
        let oldKey = ServerCredentials.keychainKey(for: id)
        let credKey = ServerCredentials.keychainKey(for: selection.id)
        let oldCredentials = try await keychain.retrieve(ServerCredentials.self, forKey: oldKey)
        let previousCredentials = try await keychain.retrieve(ServerCredentials.self, forKey: credKey)
        let creds = ServerCredentials(password: password, customHeaders: customHeaders,
                                      audioMuseToken: oldCredentials?.audioMuseToken)
        if selection.id != id, activeServerSnapshot?.id == id { await libraryChangeHandler?() }
        try await keychain.store(creds, forKey: credKey)
        do {
            let updatedActiveServer: ServerSnapshot? = try await MainActor.run {
                let context = ModelContext(modelContainer)
                context.autosaveEnabled = false
                guard let config = try context.fetch(FetchDescriptor<ServerConfig>(predicate: #Predicate { $0.id == id })).first else {
                    throw MinidiscError.serverNotFound(id: id)
                }
                config.id = selection.id
                config.libraryScopesData = selection.data
                config.displayName = displayName
                config.baseURL = baseURL
                config.username = username
                try context.save()
                let snapshot = ServerSnapshot(from: config)
                if let index = state.servers.firstIndex(where: { $0.id == id }) { state.servers[index] = snapshot }
                if state.activeServer?.id == id {
                    state.activeServer = snapshot
                    return snapshot
                }
                return nil as ServerSnapshot?
            }
            // Old media and metadata keep their old scope. No file is deleted or reassigned.
            if let updatedActiveServer {
                await publishConnectionChange(server: updatedActiveServer, credentials: creds)
            }
            if credKey != oldKey { try? await keychain.delete(forKey: oldKey) }
        } catch {
            if let previousCredentials { try? await keychain.store(previousCredentials, forKey: credKey) }
            else { try? await keychain.delete(forKey: credKey) }
            throw error
        }
    }

    func loadPersistedState() async {
        await acquireConfiguration()
        defer { releaseConfiguration() }
        do {
            let (serverIDs, activeServer) = try await MainActor.run {
                let context = ModelContext(modelContainer)
                let configs = try context.fetch(FetchDescriptor<ServerConfig>())
                state.servers = configs.map { ServerSnapshot(from: $0) }
                state.activeServer = configs.first(where: { $0.isActive }).map { ServerSnapshot(from: $0) }
                state.isLoadingPersistedState = false
                return (configs.map(\.id), state.activeServer)
            }
            if let activeServer {
                let credentials = try? await keychain.retrieve(
                    ServerCredentials.self,
                    forKey: ServerCredentials.keychainKey(for: activeServer.id)
                )
                await publishConnectionChange(server: activeServer, credentials: credentials, restoringSession: true)
            } else {
                await publishConnectionRemoval()
            }
            await migrateCredentialsAccessibility(for: serverIDs)
        } catch {
            await MainActor.run { state.isLoadingPersistedState = false }
        }
    }

    /// Updates Keychain accessibility for lock-screen playback; safe to repeat at startup.
    private func migrateCredentialsAccessibility(for serverIDs: [UUID]) async {
        for id in serverIDs {
            let key = ServerCredentials.keychainKey(for: id)
            do {
                guard let creds = try await keychain.retrieve(ServerCredentials.self, forKey: key) else {
                    Logger.server.warning("Keychain migration: no credential found for server id=\(id, privacy: .public), skipping")
                    continue
                }
                try await keychain.store(creds, forKey: key)
                Logger.server.info("Keychain migration: credential migrated for server id=\(id, privacy: .public)")
            } catch {
                Logger.server.warning("Keychain migration: skipped server id=\(id, privacy: .public) — \(error, privacy: .public)")
            }
        }
    }

    func testConnection() async throws {
        let client = try await activeConnection().makeSwiftSonicClient()
        try await client.ping()
    }

    func testConnection(
        url: String,
        username: String,
        password: String,
        customHeaders: [String: String]
    ) async throws {
        guard let serverURL = URL(string: url.trimmingCharacters(in: .whitespaces)),
              serverURL.scheme != nil, serverURL.host != nil else {
            throw ConnectionTestError.invalidURL
        }
        let transport = CustomHeadersTransport(headers: customHeaders)
        let client = SwiftSonicClient(
            configuration: ServerConfiguration(serverURL: serverURL, username: username, password: password),
            transport: transport,
            retryPolicy: .none,
            logSubsystem: "app.minidisc.server"
        )
        do {
            try await client.ping()
        } catch {
            throw mapToConnectionTestError(error)
        }
        do {
            _ = try await client.getUser(username: username)
        } catch {
            throw mapToConnectionTestError(error)
        }
    }

    func activeConnectionVersion() async -> ServerConnection.Version? {
        connectionVersion
    }

    func activeConnection() async throws -> ServerConnection {
        guard let activeConnectionSnapshot else {
            throw MinidiscError.serverNotConfigured
        }
        return activeConnectionSnapshot
    }

    // MARK: - AudioMuse

    /// Updates AudioMuse separately from server credentials. A nil endpoint also deletes its token.
    func setAudioMuseConfig(serverId: UUID, urlString: String?, token: String?) async throws {
        await acquireConfiguration()
        defer { releaseConfiguration() }
        let trimmedURL = urlString?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedURL = (trimmedURL?.isEmpty == false) ? trimmedURL : nil
        let trimmedToken = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedToken = (resolvedURL != nil && trimmedToken?.isEmpty == false) ? trimmedToken : nil

        let credKey = ServerCredentials.keychainKey(for: serverId)
        guard let existing = try await keychain.retrieve(ServerCredentials.self, forKey: credKey) else {
            throw MinidiscError.serverNotConfigured
        }
        // Keychain first, mirroring updateServer's rollback strategy: a failure here leaves both
        // stores on the old value rather than the URL pointing at an instance with no token.
        try await keychain.store(
            ServerCredentials(password: existing.password, customHeaders: existing.customHeaders, audioMuseToken: resolvedToken),
            forKey: credKey
        )

        do {
            let updatedActiveServer: ServerSnapshot? = try await MainActor.run {
                let context = ModelContext(modelContainer)
                let descriptor = FetchDescriptor<ServerConfig>(predicate: #Predicate { $0.id == serverId })
                guard let config = try context.fetch(descriptor).first else {
                    throw MinidiscError.serverNotFound(id: serverId)
                }
                config.audioMuseURL = resolvedURL
                try context.save()
                let snapshot = ServerSnapshot(from: config)
                if let idx = state.servers.firstIndex(where: { $0.id == serverId }) {
                    state.servers[idx] = snapshot
                }
                if state.activeServer?.id == serverId {
                    state.activeServer = snapshot
                    return snapshot
                }
                return nil
            }
            if let updatedActiveServer {
                let updatedCredentials = ServerCredentials(
                    password: existing.password,
                    customHeaders: existing.customHeaders,
                    audioMuseToken: resolvedToken
                )
                await publishConnectionChange(
                    server: updatedActiveServer,
                    credentials: updatedCredentials
                )
            }
        } catch {
            // The URL and its token are one logical setting. If SwiftData rejects the URL
            // update, put the previous token back so the two stores cannot disagree.
            try? await keychain.store(existing, forKey: credKey)
            throw error
        }
        Logger.server.info("AudioMuse endpoint \(resolvedURL == nil ? "cleared" : "set", privacy: .public) for server \(serverId.uuidString, privacy: .public)")
    }

    // MARK: - Private

    private func publishConnectionChange(
        server: ServerSnapshot,
        credentials: ServerCredentials?,
        restoringSession: Bool = false
    ) async {
        nextConnectionRevision &+= 1
        let version = ServerConnection.Version(
            serverID: server.id,
            revision: nextConnectionRevision
        )
        let connection = credentials.flatMap { credentials in
            try? ServerConnection(
                version: version,
                server: server,
                credentials: credentials
            )
        }
        if let compatibility, let connection {
            do {
                try await compatibility.prepare(connection, restoringSession: restoringSession)
            } catch {
                Logger.server.error("Navidrome compatibility update incomplete; will retry at next activation: \(error, privacy: .public)")
            }
        }
        // A different activation can win while the read-only version probe is awaiting.
        guard version.revision == nextConnectionRevision else { return }
        activeServerSnapshot = server
        connectionVersion = version
        activeConnectionSnapshot = connection
        await MainActor.run {
            state.activeConnectionVersion = version
        }

        if let url = URL(string: server.baseURL) {
            playbackDiagnostics.record(
                .connectionChanged(
                    version: version,
                    endpoint: PlaybackDiagnostics.ServerEndpoint(
                        url: url,
                        customHeaderCount: credentials?.customHeaders.count
                    )
                )
            )
        }
    }

    private func publishConnectionRemoval() async {
        nextConnectionRevision &+= 1
        activeServerSnapshot = nil
        activeConnectionSnapshot = nil
        connectionVersion = nil
        await MainActor.run {
            state.activeConnectionVersion = nil
        }
        playbackDiagnostics.record(.connectionRemoved)
    }

    func mapToConnectionTestError(_ error: Error) -> ConnectionTestError {
        guard let sonic = error as? SwiftSonicError else {
            let e = error as NSError
            Logger.server.error("Connection test failed — non-SwiftSonic error: domain=\(e.domain, privacy: .public) code=\(e.code, privacy: .public)")
            return .unknown(domain: e.domain, code: e.code)
        }

        switch sonic {
        case .network(let urlError):
            Logger.server.error("Connection test failed — URLError code=\(urlError.code.rawValue, privacy: .public)")
        case .httpError(let statusCode, let endpoint, let serverHost):
            Logger.server.error("Connection test failed — HTTP \(statusCode, privacy: .public) endpoint=\(endpoint, privacy: .public) host=\(serverHost ?? "nil", privacy: .public)")
        case .api(let apiError):
            Logger.server.error("Connection test failed — Subsonic API error code=\(apiError.code.rawValue, privacy: .public) endpoint=\(apiError.endpoint, privacy: .public)")
        case .decoding(_, let rawData):
            Logger.server.error("Connection test failed — decoding error, rawData.count=\(rawData.count, privacy: .public)")
        case .rateLimited(let retryAfter, let endpoint, let serverHost):
            let retryAfterStr = retryAfter.map { "\($0)" } ?? "nil"
            Logger.server.error("Connection test failed — rate limited endpoint=\(endpoint, privacy: .public) host=\(serverHost ?? "nil", privacy: .public) retryAfterSecs=\(retryAfterStr, privacy: .public)")
        case .invalidConfiguration(let reason):
            Logger.server.error("Connection test failed — invalidConfiguration: \(reason, privacy: .public)")
        case .insecureRedirect(let from, let to):
            Logger.server.error("Connection test failed — insecureRedirect from=\(from.host ?? "nil", privacy: .public) to=\(to.host ?? "nil", privacy: .public)")
        }

        switch sonic {
        case .network(let urlError):
            if sonic.isDNSFailure { return .dnsFailure }
            if sonic.isCertificateError { return .certificate }
            switch urlError.code {
            case .appTransportSecurityRequiresSecureConnection:
                return .atsBlocked
            case .timedOut:
                return .timeout
            default:
                return .cannotConnect
            }
        case .httpError(let statusCode, _, _):
            if statusCode == 401 || statusCode == 403 { return .unauthorized }
            return .httpError(statusCode: statusCode)
        case .api(let apiError):
            if sonic.isAuthenticationFailure { return .unauthorized }
            return .subsonicError(code: apiError.code, message: apiError.message)
        case .decoding:
            return .notSubsonicServer
        case .rateLimited:
            return .httpError(statusCode: 429)
        case .invalidConfiguration:
            return .invalidConfiguration
        case .insecureRedirect:
            return .insecureRedirect
        }
    }

    private func validateHeaders(_ headers: [String: String]) throws {
        for (key, value) in headers {
            guard HeaderValidator.isValidName(key) else {
                throw MinidiscError.invalidHeaderName(key: key)
            }
            guard HeaderValidator.isValidValue(value) else {
                throw MinidiscError.invalidHeaderValue(key: key)
            }
        }
    }
}
