import CryptoKit
import Foundation
import OSLog

nonisolated struct PendingListenQueueFile: Codable, Sendable {
    let accountFingerprint: String?
    let listens: [PendingListen]
}

actor ListenBrainzService {
    // Reuses the shared KeychainService actor (service group = "app.minidisc.server-credentials").
    // The key "listenbrainz-username" is namespaced to prevent collision with server credentials.
    private static let usernameKeychainKey = "listenbrainz-username"
    private static let isEnabledDefaultsKey = "app.minidisc.listenbrainz.isEnabled"

    // MARK: - Scrobbling Keychain / UserDefaults keys

    private static let scrobblingTokenKeychainKey    = "app.minidisc.listenbrainz.token"
    private static let scrobblingUsernameKeychainKey = "app.minidisc.listenbrainz.username"
    private static let scrobblingEnabledDefaultsKey  = "app.minidisc.listenbrainz.scrobbling.isEnabled"
    private static let scrobblingServerURLDefaultsKey = "app.minidisc.listenbrainz.scrobbling.serverRootURL"
    /// Durable transaction fence. It is set before the first write of the two-key credential
    /// pair and cleared only after a complete commit, complete rollback, or complete purge.
    /// A process restart can therefore never reactivate credentials left between two writes.
    private static let scrobblingCredentialsInvalidDefaultsKey =
        "app.minidisc.listenbrainz.scrobbling.credentialsInvalid"
    static let defaultScrobblingServerURL = "https://api.listenbrainz.org"

    private let client: ListenBrainzClient
    private let keychain: any KeychainServiceProtocol
    private let userDefaults: UserDefaults

    // MARK: - Recommendations state

    private var isEnabled: Bool
    private var username: String?
    private var validationStatus: ValidationStatus = .unknown
    /// Monotonically identifies the latest recommendations configuration intent.
    /// Every continuation checks it after an `await` before committing state.
    private var recommendationsOperationGeneration: UInt64 = 0

    // MARK: - Scrobbling state

    private var scrobblingEnabled: Bool = false
    private var scrobblingUsername: String?
    private var scrobblingValidationStatus: ValidationStatus = .unknown
    /// True when a token is present in the Keychain. Set in loadPersistedState and on token store/clear.
    /// Avoids a Keychain round-trip for every track change when scrobbling is not configured.
    private var hasScrobblingToken: Bool = false
    /// Identifies the latest credential/configuration intent (validate, enable, disable, or clear).
    private var scrobblingOperationGeneration: UInt64 = 0
    /// Identifies the active account used for submissions and queue ownership.
    private var scrobblingAccountGeneration: UInt64 = 0
    /// Non-nil only while validated credentials are being committed to Keychain.
    /// Submissions pause during this short non-atomic two-key update.
    private var scrobblingCredentialCommitOperation: UInt64?
    /// Serializes multi-key Keychain mutations across suspension points. Configuration
    /// intents wait before changing their generation, so an in-progress commit remains
    /// current until it has either completed or rolled back.
    private var credentialMutationInProgress = false
    private var credentialMutationWaiters: [CheckedContinuation<Void, Never>] = []
    /// Stable, non-secret ownership marker persisted alongside the offline queue.
    private var scrobblingAccountFingerprint: String?

    // MARK: - Offline queue

    private let queueFileURL: URL
    private var pendingQueue: [PendingListen] = []
    /// Guards against two concurrent flushes re-POSTing the same batch.
    /// Set synchronously before the first await in flushOfflineQueue; reset via defer.
    private var isFlushing: Bool = false

    /// Number of listens waiting for a successful flush. Exposed for diagnostics and tests.
    var pendingListenCount: Int { pendingQueue.count }
    /// Number of configuration intents suspended behind a multi-key Keychain mutation.
    /// Kept internal so deterministic re-entrancy tests can observe the serialization point.
    var credentialMutationWaiterCount: Int { credentialMutationWaiters.count }

    init(
        client: ListenBrainzClient,
        keychain: any KeychainServiceProtocol,
        userDefaults: UserDefaults = .standard,
        queueFileURL: URL? = nil
    ) {
        self.client = client
        self.keychain = keychain
        self.userDefaults = userDefaults
        self.isEnabled = userDefaults.bool(forKey: Self.isEnabledDefaultsKey)
        self.queueFileURL = queueFileURL ?? Self.makeDefaultQueueFileURL()
    }

    /// Resolves the default queue file path in Application Support, creating the subdirectory if needed.
    /// Falls back to the temporary directory on unexpected filesystem errors.
    private static func makeDefaultQueueFileURL() -> URL {
        do {
            let appSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let dir = appSupport.appendingPathComponent("app.minidisc", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.appendingPathComponent("listenbrainz-queue.json")
        } catch {
            Logger.listenBrainz.error("Failed to resolve Application Support path: \(error, privacy: .public)")
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("app.minidisc.listenbrainz-queue.json")
        }
    }

    /// Loads persisted state for both recommendations and scrobbling.
    /// Call once from AppContainer after init.
    func loadPersistedState() async {
        await loadRecommendationsState()
        await loadScrobblingState()
    }

    private func loadRecommendationsState() async {
        await waitForCredentialMutation()
        let operation = beginRecommendationsOperation()

        // Recommendations
        let persistedUsername = try? await keychain.retrieve(String.self, forKey: Self.usernameKeychainKey)
        guard isCurrentRecommendationsOperation(operation) else { return }
        username = persistedUsername
        Logger.listenBrainz.debug("State loaded — isEnabled=\(self.isEnabled, privacy: .public) hasUsername=\(self.username != nil, privacy: .public)")
        if persistedUsername != nil {
            try? await revalidate()
        }
    }

    private func loadScrobblingState() async {
        await waitForCredentialMutation()
        let operation = beginScrobblingOperation()
        let persistedEnabled = userDefaults.bool(forKey: Self.scrobblingEnabledDefaultsKey)

        if userDefaults.bool(forKey: Self.scrobblingCredentialsInvalidDefaultsKey) {
            beginCredentialMutation()
            scrobblingCredentialCommitOperation = operation
            defer {
                scrobblingCredentialCommitOperation = nil
                endCredentialMutation()
            }
            await quarantineAndPurgeScrobblingCredentials()
            Logger.listenBrainz.warning(
                "Discarded an incomplete scrobbling credential transaction during state restoration"
            )
            return
        }

        // Scrobbling
        let persistedUsername = try? await keychain.retrieve(String.self, forKey: Self.scrobblingUsernameKeychainKey)
        guard isCurrentScrobblingOperation(operation) else { return }
        let storedToken = try? await keychain.retrieve(String.self, forKey: Self.scrobblingTokenKeychainKey)
        guard isCurrentScrobblingOperation(operation) else { return }

        scrobblingEnabled = persistedEnabled && storedToken != nil
        scrobblingUsername = persistedUsername
        scrobblingValidationStatus = storedToken == nil ? .unknown : .valid
        hasScrobblingToken = storedToken != nil
        if persistedEnabled && storedToken == nil {
            userDefaults.set(false, forKey: Self.scrobblingEnabledDefaultsKey)
        }
        let rootURL = userDefaults.string(forKey: Self.scrobblingServerURLDefaultsKey)
            ?? Self.defaultScrobblingServerURL
        scrobblingAccountFingerprint = storedToken.map {
            Self.accountFingerprint(token: $0, rootURL: rootURL)
        }
        markScrobblingAccountChanged()
        Logger.listenBrainz.debug("Scrobbling state loaded — enabled=\(self.scrobblingEnabled, privacy: .public) hasToken=\(self.hasScrobblingToken, privacy: .public)")

        // Offline queue — load persisted listens then attempt an immediate flush
        loadQueue()
        await flushOfflineQueue()
    }

    // MARK: - Recommendations public interface

    func currentSnapshot() -> ListenBrainzSnapshot {
        ListenBrainzSnapshot(isEnabled: isEnabled, username: username, validationStatus: validationStatus)
    }

    /// Validates the username against ListenBrainz. On success, persists and flips isEnabled.
    func enable(username: String) async throws {
        await waitForCredentialMutation()
        let operation = beginRecommendationsOperation()
        validationStatus = .validating
        do {
            _ = try await client.validateUsername(username)
        } catch {
            guard isCurrentRecommendationsOperation(operation) else { return }
            validationStatus = .invalid(reason: error.localizedDescription)
            throw error
        }
        guard isCurrentRecommendationsOperation(operation) else { return }

        await waitForCredentialMutation()
        guard isCurrentRecommendationsOperation(operation) else { return }
        beginCredentialMutation()
        defer { endCredentialMutation() }
        do {
            try await keychain.store(username, forKey: Self.usernameKeychainKey)
        } catch {
            guard isCurrentRecommendationsOperation(operation) else { return }
            validationStatus = .invalid(reason: error.localizedDescription)
            throw error
        }
        guard isCurrentRecommendationsOperation(operation) else { return }

        self.username = username
        isEnabled = true
        userDefaults.set(true, forKey: Self.isEnabledDefaultsKey)
        validationStatus = .valid
        Logger.listenBrainz.info("ListenBrainz enabled")
    }

    /// Disables integration. Username is intentionally kept in Keychain so re-enabling
    /// requires no re-entry — minimal friction for temporary disconnection.
    func disable() async {
        await waitForCredentialMutation()
        _ = beginRecommendationsOperation()
        isEnabled = false
        if validationStatus == .validating {
            validationStatus = .unknown
        }
        userDefaults.set(false, forKey: Self.isEnabledDefaultsKey)
        Logger.listenBrainz.info("ListenBrainz disabled")
    }

    /// Re-runs username validation if a username is stored. No-op if no username is persisted.
    func revalidate() async throws {
        await waitForCredentialMutation()
        let operation = beginRecommendationsOperation()
        guard let existing = username else {
            Logger.listenBrainz.debug("revalidate: no username stored, skipping")
            return
        }
        validationStatus = .validating
        do {
            _ = try await client.validateUsername(existing)
            guard isCurrentRecommendationsOperation(operation) else { return }
            validationStatus = .valid
            Logger.listenBrainz.info("revalidate succeeded")
        } catch {
            guard isCurrentRecommendationsOperation(operation) else { return }
            validationStatus = .invalid(reason: error.localizedDescription)
            throw error
        }
    }

    /// Purges all recommendations state — username, enabled flag, validation status.
    func clearCredentials() async {
        await waitForCredentialMutation()
        _ = beginRecommendationsOperation()
        beginCredentialMutation()
        defer { endCredentialMutation() }
        username = nil
        isEnabled = false
        validationStatus = .unknown
        userDefaults.set(false, forKey: Self.isEnabledDefaultsKey)
        try? await keychain.delete(forKey: Self.usernameKeychainKey)
        Logger.listenBrainz.info("ListenBrainz credentials cleared")
    }

    // MARK: - Scrobbling public interface

    func scrobblingSnapshot() -> ScrobblingSnapshot {
        ScrobblingSnapshot(
            isEnabled: scrobblingEnabled,
            username: scrobblingUsername,
            serverRootURL: userDefaults.string(forKey: Self.scrobblingServerURLDefaultsKey) ?? Self.defaultScrobblingServerURL,
            validationStatus: scrobblingValidationStatus
        )
    }

    /// Validates `token` against `rootURL`, persists credentials on success, and enables scrobbling.
    /// Throws `ListenBrainzError.unauthorized` when the server responds with valid:false.
    /// Token is never included in log output or error messages.
    func validateAndSaveScrobblingToken(_ token: String, rootURL: URL) async throws {
        await waitForCredentialMutation()
        let operation = beginScrobblingOperation()
        let previousRuntimeState = (
            enabled: scrobblingEnabled,
            username: scrobblingUsername,
            validationStatus: scrobblingValidationStatus,
            hasToken: hasScrobblingToken,
            accountFingerprint: scrobblingAccountFingerprint
        )
        scrobblingValidationStatus = .validating

        let normalizedURL = Self.normalizeServerURL(rootURL.absoluteString)
        let previousURL = Self.normalizeServerURL(
            userDefaults.string(forKey: Self.scrobblingServerURLDefaultsKey)
                ?? Self.defaultScrobblingServerURL
        )
        let previousCredentialSetWasInvalid = userDefaults.bool(
            forKey: Self.scrobblingCredentialsInvalidDefaultsKey
        )
        let previousToken: String?
        let previousUsername: String?
        if previousCredentialSetWasInvalid {
            // A previous interrupted transaction is not a rollback candidate. A failed
            // replacement must purge it rather than bless the partial pair as an old account.
            previousToken = nil
            previousUsername = nil
        } else {
            previousToken = try await keychain.retrieve(
                String.self,
                forKey: Self.scrobblingTokenKeychainKey
            )
            guard isCurrentScrobblingOperation(operation) else { return }
            previousUsername = try await keychain.retrieve(
                String.self,
                forKey: Self.scrobblingUsernameKeychainKey
            )
            guard isCurrentScrobblingOperation(operation) else { return }
        }

        let result: ListenBrainzValidation
        do {
            result = try await client.validateToken(token, rootURL: rootURL)
        } catch {
            guard isCurrentScrobblingOperation(operation) else { return }
            scrobblingValidationStatus = .invalid(reason: error.localizedDescription)
            throw error
        }
        guard isCurrentScrobblingOperation(operation) else { return }

        guard result.isValid else {
            scrobblingValidationStatus = .invalid(reason: "Token is not valid for this server.")
            throw ListenBrainzError.unauthorized
        }

        let accountChanged = previousCredentialSetWasInvalid
            || previousToken != token
            || previousURL != normalizedURL
        await waitForCredentialMutation()
        guard isCurrentScrobblingOperation(operation) else { return }
        beginCredentialMutation()
        scrobblingCredentialCommitOperation = operation
        // This synchronous write precedes the first Keychain suspension point. If the app
        // terminates between the token and username writes, the next instance quarantines
        // the incomplete pair instead of treating it as a configured account.
        userDefaults.set(true, forKey: Self.scrobblingCredentialsInvalidDefaultsKey)
        defer {
            if scrobblingCredentialCommitOperation == operation {
                scrobblingCredentialCommitOperation = nil
            }
            endCredentialMutation()
        }

        do {
            try await keychain.store(token, forKey: Self.scrobblingTokenKeychainKey)

            if let username = result.username {
                try await keychain.store(username, forKey: Self.scrobblingUsernameKeychainKey)
            } else {
                // A self-hosted compatible server may validate tokens without returning a username.
                // Do not keep displaying the account name from a previously configured server.
                try await keychain.delete(forKey: Self.scrobblingUsernameKeychainKey)
            }
        } catch {
            let commitError = error
            // Both rollback legs are attempted independently. Stopping after the first
            // failure can leave the other key carrying the replacement account.
            let tokenRestored = await restoreKeychainValue(
                previousToken,
                forKey: Self.scrobblingTokenKeychainKey
            )
            let usernameRestored = await restoreKeychainValue(
                previousUsername,
                forKey: Self.scrobblingUsernameKeychainKey
            )

            if tokenRestored && usernameRestored && !previousCredentialSetWasInvalid {
                scrobblingEnabled = previousRuntimeState.enabled
                scrobblingUsername = previousRuntimeState.username
                scrobblingValidationStatus = previousRuntimeState.validationStatus
                hasScrobblingToken = previousRuntimeState.hasToken
                scrobblingAccountFingerprint = previousRuntimeState.accountFingerprint
                userDefaults.removeObject(
                    forKey: Self.scrobblingCredentialsInvalidDefaultsKey
                )
            } else {
                // Ownership is now uncertain. Disable immediately and delete each key
                // independently; a durable marker keeps any undeletable survivor inert.
                await quarantineAndPurgeScrobblingCredentials()
                scrobblingValidationStatus = .invalid(
                    reason: commitError.localizedDescription
                )
                Logger.listenBrainz.error(
                    "Could not restore the previous scrobbling credential pair; credentials quarantined"
                )
            }
            throw commitError
        }

        if accountChanged {
            scrobblingAccountFingerprint = Self.accountFingerprint(
                token: token,
                rootURL: normalizedURL
            )
            clearPendingQueue()
        } else if scrobblingAccountFingerprint == nil {
            scrobblingAccountFingerprint = Self.accountFingerprint(
                token: token,
                rootURL: normalizedURL
            )
        }
        hasScrobblingToken = true
        scrobblingUsername = result.username
        userDefaults.set(normalizedURL, forKey: Self.scrobblingServerURLDefaultsKey)
        scrobblingEnabled = true
        userDefaults.set(true, forKey: Self.scrobblingEnabledDefaultsKey)
        scrobblingValidationStatus = .valid
        markScrobblingAccountChanged()
        // Last durable commit step: both Keychain values and their URL/enable metadata
        // now describe the same account.
        userDefaults.removeObject(forKey: Self.scrobblingCredentialsInvalidDefaultsKey)
        Logger.listenBrainz.info("Scrobbling token validated and saved")
    }

    /// Re-enables scrobbling without re-validating. No-op if no token has been stored.
    func enableScrobbling() async {
        await waitForCredentialMutation()
        guard hasScrobblingToken,
              !userDefaults.bool(forKey: Self.scrobblingCredentialsInvalidDefaultsKey)
        else { return }
        _ = beginScrobblingOperation()
        scrobblingCredentialCommitOperation = nil
        let wasEnabled = scrobblingEnabled
        scrobblingEnabled = true
        userDefaults.set(true, forKey: Self.scrobblingEnabledDefaultsKey)
        if !wasEnabled {
            markScrobblingAccountChanged()
        }
        Logger.listenBrainz.info("Scrobbling re-enabled")
    }

    /// Disables scrobbling without removing the stored token — low-friction re-enable.
    func disableScrobbling() async {
        await waitForCredentialMutation()
        _ = beginScrobblingOperation()
        scrobblingCredentialCommitOperation = nil
        let wasEnabled = scrobblingEnabled
        scrobblingEnabled = false
        if scrobblingValidationStatus == .validating {
            scrobblingValidationStatus = .unknown
        }
        userDefaults.set(false, forKey: Self.scrobblingEnabledDefaultsKey)
        if wasEnabled {
            markScrobblingAccountChanged()
        }
        Logger.listenBrainz.info("Scrobbling disabled")
    }

    /// Purges scrobbling token, username, all related config, and the offline queue.
    /// The queue belongs to the removed account — it must never flush to a different future account.
    func clearScrobblingToken() async {
        await waitForCredentialMutation()
        let operation = beginScrobblingOperation()
        beginCredentialMutation()
        scrobblingCredentialCommitOperation = operation
        defer {
            scrobblingCredentialCommitOperation = nil
            endCredentialMutation()
        }
        await quarantineAndPurgeScrobblingCredentials()
        scrobblingValidationStatus = .unknown
        Logger.listenBrainz.info("Scrobbling credentials cleared")
    }

    // MARK: - Scrobbling notifications (called by PlayerService)

    /// Submits a playing_now notification to ListenBrainz. No-op when scrobbling is disabled or
    /// no token is stored. The 3-second delay and still-playing guard are applied by the caller.
    /// playing_now failures are NEVER queued — they are ephemeral and stale by flush time.
    func notifyTrackStarted(song: DisplayableSong) async {
        guard let accountGeneration = activeScrobblingAccountGeneration() else { return }
        guard let token = try? await keychain.retrieve(String.self, forKey: Self.scrobblingTokenKeychainKey) else { return }
        guard isCurrentActiveScrobblingAccount(accountGeneration) else { return }
        let rootURLString = userDefaults.string(forKey: Self.scrobblingServerURLDefaultsKey) ?? Self.defaultScrobblingServerURL
        guard let rootURL = URL(string: rootURLString) else { return }
        do {
            try await client.submitPlayingNow(track: LBTrackMetadata(from: song), rootURL: rootURL, token: token)
            guard isCurrentActiveScrobblingAccount(accountGeneration) else { return }
            Logger.listenBrainz.debug("playing_now submitted")
        } catch {
            Logger.listenBrainz.debug("playing_now failed: \(error, privacy: .public)")
        }
    }

    /// Submits a single completed listen to ListenBrainz. On transient failure the listen is
    /// persisted to the offline queue. On permanent failure (auth/4xx) it is dropped.
    func notifyScrobbleThreshold(song: DisplayableSong, startDate: Date) async {
        guard let accountGeneration = activeScrobblingAccountGeneration() else { return }
        guard let token = try? await keychain.retrieve(String.self, forKey: Self.scrobblingTokenKeychainKey) else { return }
        guard isCurrentActiveScrobblingAccount(accountGeneration) else { return }
        let rootURLString = userDefaults.string(forKey: Self.scrobblingServerURLDefaultsKey) ?? Self.defaultScrobblingServerURL
        guard let rootURL = URL(string: rootURLString) else { return }
        let listenedAt = Int(startDate.timeIntervalSince1970)
        let meta = LBTrackMetadata(from: song)
        do {
            try await client.submitListen(track: meta, listenedAt: listenedAt, rootURL: rootURL, token: token)
            guard isCurrentActiveScrobblingAccount(accountGeneration) else { return }
            Logger.listenBrainz.debug("single listen submitted")
            await flushOfflineQueue()
        } catch {
            guard isCurrentActiveScrobblingAccount(accountGeneration), !Task.isCancelled else { return }
            let isTransient = (error as? ListenBrainzError)?.isTransient ?? true
            if isTransient {
                enqueue(PendingListen(
                    listenedAt: listenedAt,
                    trackName: meta.trackName,
                    artistName: meta.artistName,
                    releaseName: meta.releaseName,
                    durationMs: meta.durationMs
                ))
                Logger.listenBrainz.debug("single listen queued after transient error")
            } else {
                Logger.listenBrainz.debug("single listen dropped (permanent error)")
            }
        }
    }

    // MARK: - Offline queue — flush

    /// Attempts to POST all pending listens as a single "import" batch.
    /// Triggers: reconnect (MinidiscApp .task), app launch (loadPersistedState),
    /// after any successful live single submit (free online signal).
    ///
    /// Re-entrancy: isFlushing is set synchronously before the first await, preventing
    /// two concurrent callers from both building and posting the same batch. On confirmed
    /// 200 only the submitted batch is dropped; listens enqueued during the POST are kept.
    func flushOfflineQueue() async {
        guard !pendingQueue.isEmpty else { return }
        guard scrobblingEnabled, hasScrobblingToken else { return }
        guard scrobblingCredentialCommitOperation == nil else { return }
        guard !isFlushing else { return }
        let accountGeneration = scrobblingAccountGeneration
        isFlushing = true
        defer { isFlushing = false }

        guard let token = try? await keychain.retrieve(String.self, forKey: Self.scrobblingTokenKeychainKey) else { return }
        guard isCurrentActiveScrobblingAccount(accountGeneration) else { return }
        let rootURLString = userDefaults.string(forKey: Self.scrobblingServerURLDefaultsKey) ?? Self.defaultScrobblingServerURL
        guard let rootURL = URL(string: rootURLString) else { return }

        let batch = pendingQueue
        let listens = batch.map { listen in
            (
                listenedAt: listen.listenedAt,
                track: LBTrackMetadata(
                    trackName: listen.trackName,
                    artistName: listen.artistName,
                    releaseName: listen.releaseName,
                    durationMs: listen.durationMs
                )
            )
        }

        do {
            try await client.submitImport(listens: listens, rootURL: rootURL, token: token)
            guard isCurrentActiveScrobblingAccount(accountGeneration),
                  pendingQueue.starts(with: batch)
            else {
                Logger.listenBrainz.debug("Ignoring stale offline queue flush result")
                return
            }
            pendingQueue.removeFirst(batch.count)
            saveQueue()
            Logger.listenBrainz.info("Offline queue flushed: \(batch.count, privacy: .public) listens")
        } catch {
            Logger.listenBrainz.debug("Offline queue flush failed, will retry: \(error, privacy: .public)")
        }
    }

    // MARK: - Offline queue — persistence helpers

    private func loadQueue() {
        guard FileManager.default.fileExists(atPath: queueFileURL.path) else { return }
        do {
            let data = try Data(contentsOf: queueFileURL)
            let persisted = try JSONDecoder().decode(PendingListenQueueFile.self, from: data)
            guard persisted.accountFingerprint == scrobblingAccountFingerprint else {
                Logger.listenBrainz.warning(
                    "Discarding an offline queue that belongs to a different scrobbling account"
                )
                clearPendingQueue()
                return
            }
            pendingQueue = persisted.listens
            Logger.listenBrainz.debug("Loaded \(self.pendingQueue.count, privacy: .public) pending listens from queue")
        } catch {
            Logger.listenBrainz.error("Pending listens queue is corrupt, starting empty: \(error, privacy: .public)")
            clearPendingQueue()
        }
    }

    private func saveQueue() {
        let dir = queueFileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            let data = try JSONEncoder().encode(PendingListenQueueFile(
                accountFingerprint: scrobblingAccountFingerprint,
                listens: pendingQueue
            ))
            try data.write(to: queueFileURL, options: .atomic)
        } catch {
            Logger.listenBrainz.error("Failed to save pending listens queue: \(error, privacy: .public)")
        }
    }

    private func enqueue(_ listen: PendingListen) {
        pendingQueue.append(listen)
        saveQueue()
        Logger.listenBrainz.debug("Enqueued pending listen; queue size=\(self.pendingQueue.count, privacy: .public)")
    }

    // MARK: - Helpers

    @discardableResult
    private func beginRecommendationsOperation() -> UInt64 {
        recommendationsOperationGeneration &+= 1
        return recommendationsOperationGeneration
    }

    private func isCurrentRecommendationsOperation(_ generation: UInt64) -> Bool {
        recommendationsOperationGeneration == generation
    }

    @discardableResult
    private func beginScrobblingOperation() -> UInt64 {
        scrobblingOperationGeneration &+= 1
        return scrobblingOperationGeneration
    }

    private func isCurrentScrobblingOperation(_ generation: UInt64) -> Bool {
        scrobblingOperationGeneration == generation
    }

    private func markScrobblingAccountChanged() {
        scrobblingAccountGeneration &+= 1
    }

    private func activeScrobblingAccountGeneration() -> UInt64? {
        guard scrobblingEnabled,
              hasScrobblingToken,
              scrobblingCredentialCommitOperation == nil,
              !userDefaults.bool(forKey: Self.scrobblingCredentialsInvalidDefaultsKey)
        else { return nil }
        return scrobblingAccountGeneration
    }

    private func isCurrentActiveScrobblingAccount(_ generation: UInt64) -> Bool {
        activeScrobblingAccountGeneration() == generation
    }

    private func clearPendingQueue() {
        pendingQueue.removeAll()
        guard FileManager.default.fileExists(atPath: queueFileURL.path) else { return }
        do {
            try FileManager.default.removeItem(at: queueFileURL)
        } catch {
            Logger.listenBrainz.error(
                "Failed to remove the pending listens queue: \(error, privacy: .public)"
            )
        }
    }

    private func waitForCredentialMutation() async {
        while credentialMutationInProgress {
            await withCheckedContinuation { continuation in
                credentialMutationWaiters.append(continuation)
            }
        }
    }

    private func beginCredentialMutation() {
        precondition(!credentialMutationInProgress)
        credentialMutationInProgress = true
    }

    private func endCredentialMutation() {
        guard credentialMutationInProgress else { return }
        credentialMutationInProgress = false
        let waiters = credentialMutationWaiters
        credentialMutationWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func restoreKeychainValue(_ value: String?, forKey key: String) async -> Bool {
        do {
            if let value {
                try await keychain.store(value, forKey: key)
            } else {
                try await keychain.delete(forKey: key)
            }
            return true
        } catch {
            Logger.listenBrainz.error(
                "Failed to restore Keychain value for '\(key, privacy: .public)': \(error, privacy: .public)"
            )
            return false
        }
    }

    /// Makes an uncertain credential set unusable immediately, then independently attempts
    /// to remove both keys. The durable marker is retained if either deletion fails, so a
    /// surviving key remains inert across process restarts.
    private func quarantineAndPurgeScrobblingCredentials() async {
        userDefaults.set(true, forKey: Self.scrobblingCredentialsInvalidDefaultsKey)
        markScrobblingAccountChanged()
        scrobblingEnabled = false
        scrobblingUsername = nil
        scrobblingValidationStatus = .unknown
        hasScrobblingToken = false
        scrobblingAccountFingerprint = nil
        clearPendingQueue()
        userDefaults.set(false, forKey: Self.scrobblingEnabledDefaultsKey)
        userDefaults.removeObject(forKey: Self.scrobblingServerURLDefaultsKey)

        let tokenDeleted = await deleteKeychainValue(
            forKey: Self.scrobblingTokenKeychainKey
        )
        let usernameDeleted = await deleteKeychainValue(
            forKey: Self.scrobblingUsernameKeychainKey
        )
        if tokenDeleted && usernameDeleted {
            userDefaults.removeObject(
                forKey: Self.scrobblingCredentialsInvalidDefaultsKey
            )
        }
    }

    private func deleteKeychainValue(forKey key: String) async -> Bool {
        do {
            try await keychain.delete(forKey: key)
            return true
        } catch {
            Logger.listenBrainz.error(
                "Failed to delete Keychain value for '\(key, privacy: .public)': \(error, privacy: .public)"
            )
            return false
        }
    }

    nonisolated private static func accountFingerprint(token: String, rootURL: String) -> String {
        let normalizedURL = normalizeServerURL(rootURL)
        let digest = SHA256.hash(data: Data("\(normalizedURL)\u{0}\(token)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Trims whitespace and strips trailing slashes for consistent path joining.
    nonisolated static func normalizeServerURL(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
