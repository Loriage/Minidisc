import Foundation
import Testing
@testable import Minidisc

@MainActor
private final class ReentrancyTransport: ListenBrainzTransport {
    private struct PendingRequest {
        let request: URLRequest
        let continuation: CheckedContinuation<(Data, HTTPURLResponse), any Error>
    }

    private struct RequestCountWaiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var nextRequestID = 0
    private var pending: [Int: PendingRequest] = [:]
    private var requests: [URLRequest] = []
    private var requestCountWaiters: [RequestCountWaiter] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let requestID = nextRequestID
            nextRequestID += 1
            requests.append(request)
            pending[requestID] = PendingRequest(request: request, continuation: continuation)
            resumeSatisfiedRequestCountWaiters()
        }
    }

    func waitForRequestCount(_ count: Int) async {
        guard requests.count < count else { return }
        await withCheckedContinuation { continuation in
            requestCountWaiters.append(RequestCountWaiter(count: count, continuation: continuation))
        }
    }

    @discardableResult
    func respond(to requestID: Int, status: Int, body: Data = Data()) -> Bool {
        guard let pendingRequest = pending.removeValue(forKey: requestID) else { return false }
        let response = HTTPURLResponse(
            url: pendingRequest.request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        pendingRequest.continuation.resume(returning: (body, response))
        return true
    }

    func request(at requestID: Int) -> URLRequest? {
        requests.indices.contains(requestID) ? requests[requestID] : nil
    }

    var requestCount: Int {
        requests.count
    }

    private func resumeSatisfiedRequestCountWaiters() {
        var remaining: [RequestCountWaiter] = []
        for waiter in requestCountWaiters {
            if requests.count >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        requestCountWaiters = remaining
    }
}

@MainActor
private final class ReentrancyKeychain: KeychainServiceProtocol {
    private struct MutationCountWaiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var storage: [String: Data] = [:]
    private var failingMutationIDs: Set<Int> = []
    private var suspendingMutationIDs: Set<Int> = []
    private var suspendedMutations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var mutationCountWaiters: [MutationCountWaiter] = []
    private(set) var mutations: [ReentrancyKeychainMutation] = []

    func store<T: Codable & Sendable>(_ value: T, forKey key: String) async throws {
        let data = try JSONEncoder().encode(value)
        let mutationID = registerMutation(.store(key))
        await suspendMutationIfNeeded(mutationID)
        if failingMutationIDs.remove(mutationID) != nil {
            throw ReentrancyKeychainError.plannedFailure(mutationID)
        }
        storage[key] = data
    }

    func retrieve<T: Codable & Sendable>(_ type: T.Type, forKey key: String) async throws -> T? {
        guard let data = storage[key] else { return nil }
        return try JSONDecoder().decode(type, from: data)
    }

    func delete(forKey key: String) async throws {
        let mutationID = registerMutation(.delete(key))
        await suspendMutationIfNeeded(mutationID)
        if failingMutationIDs.remove(mutationID) != nil {
            throw ReentrancyKeychainError.plannedFailure(mutationID)
        }
        storage.removeValue(forKey: key)
    }

    func seed(_ value: String, forKey key: String) throws {
        storage[key] = try JSONEncoder().encode(value)
    }

    func configure(
        failingMutationIDs: Set<Int> = [],
        suspendingMutationIDs: Set<Int> = []
    ) {
        self.failingMutationIDs = failingMutationIDs
        self.suspendingMutationIDs = suspendingMutationIDs
    }

    func waitForMutationCount(_ count: Int) async {
        guard mutations.count < count else { return }
        await withCheckedContinuation { continuation in
            mutationCountWaiters.append(
                MutationCountWaiter(count: count, continuation: continuation)
            )
        }
    }

    @discardableResult
    func resumeMutation(_ mutationID: Int) -> Bool {
        guard let continuation = suspendedMutations.removeValue(forKey: mutationID) else {
            return false
        }
        continuation.resume()
        return true
    }

    func string(forKey key: String) throws -> String? {
        guard let data = storage[key] else { return nil }
        return try JSONDecoder().decode(String.self, from: data)
    }

    private func registerMutation(_ mutation: ReentrancyKeychainMutation) -> Int {
        let mutationID = mutations.count
        mutations.append(mutation)

        var remaining: [MutationCountWaiter] = []
        for waiter in mutationCountWaiters {
            if mutations.count >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        mutationCountWaiters = remaining
        return mutationID
    }

    private func suspendMutationIfNeeded(_ mutationID: Int) async {
        guard suspendingMutationIDs.remove(mutationID) != nil else { return }
        await withCheckedContinuation { continuation in
            suspendedMutations[mutationID] = continuation
        }
    }
}

nonisolated private enum ReentrancyKeychainMutation: Equatable, Sendable {
    case store(String)
    case delete(String)
}

nonisolated private enum ReentrancyKeychainError: Error, Sendable {
    case plannedFailure(Int)
}

private let reentrancyRecommendationKey = "listenbrainz-username"
private let reentrancyTokenKey = "app.minidisc.listenbrainz.token"
private let reentrancyScrobblingUsernameKey = "app.minidisc.listenbrainz.username"
private let reentrancyScrobblingEnabledKey =
    "app.minidisc.listenbrainz.scrobbling.isEnabled"
private let reentrancyScrobblingRootURLKey =
    "app.minidisc.listenbrainz.scrobbling.serverRootURL"
private let reentrancyDefaultRoot = URL(string: ListenBrainzService.defaultScrobblingServerURL)!
private let reentrancyUsernameSuccessBody = Data(#"{"payload":{"count":0}}"#.utf8)

private func reentrancyTokenSuccessBody(username: String) -> Data {
    Data(#"{"valid":true,"user_name":"\#(username)"}"#.utf8)
}

@MainActor
private func makeReentrancyService() -> (
    service: ListenBrainzService,
    transport: ReentrancyTransport,
    keychain: ReentrancyKeychain,
    queueFileURL: URL,
    defaultsSuiteName: String
) {
    let transport = ReentrancyTransport()
    let keychain = ReentrancyKeychain()
    let queueFileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("listenbrainz-reentrancy-\(UUID().uuidString).json")
    let defaultsSuiteName = "test.listenbrainz.reentrancy.\(UUID().uuidString)"
    let service = ListenBrainzService(
        client: ListenBrainzClient(transport: transport),
        keychain: keychain,
        userDefaults: UserDefaults(suiteName: defaultsSuiteName)!,
        queueFileURL: queueFileURL
    )
    return (service, transport, keychain, queueFileURL, defaultsSuiteName)
}

@MainActor
private func seedPersistedScrobblingAccount(
    token: String,
    username: String,
    into components: (
        service: ListenBrainzService,
        transport: ReentrancyTransport,
        keychain: ReentrancyKeychain,
        queueFileURL: URL,
        defaultsSuiteName: String
    )
) async throws {
    try components.keychain.seed(token, forKey: reentrancyTokenKey)
    try components.keychain.seed(username, forKey: reentrancyScrobblingUsernameKey)
    let defaults = UserDefaults(suiteName: components.defaultsSuiteName)!
    defaults.set(true, forKey: reentrancyScrobblingEnabledKey)
    defaults.set(
        ListenBrainzService.defaultScrobblingServerURL,
        forKey: reentrancyScrobblingRootURLKey
    )
    await components.service.loadPersistedState()
}

@MainActor
private func removeReentrancyArtifacts(queueFileURL: URL, defaultsSuiteName: String) {
    try? FileManager.default.removeItem(at: queueFileURL)
    UserDefaults.standard.removePersistentDomain(forName: defaultsSuiteName)
}

@MainActor
@Suite("ListenBrainzService — reentrancy and account identity")
struct ListenBrainzReentrancyTests {
    @Test("clearCredentials wins over an older username validation")
    func clearCredentialsInvalidatesPendingEnable() async throws {
        let components = makeReentrancyService()
        defer {
            removeReentrancyArtifacts(
                queueFileURL: components.queueFileURL,
                defaultsSuiteName: components.defaultsSuiteName
            )
        }

        let enableTask = Task {
            try await components.service.enable(username: "stale-user")
        }
        await components.transport.waitForRequestCount(1)

        await components.service.clearCredentials()
        #expect(components.transport.respond(
            to: 0,
            status: 200,
            body: reentrancyUsernameSuccessBody
        ))
        try await enableTask.value

        let snapshot = await components.service.currentSnapshot()
        #expect(!snapshot.isEnabled)
        #expect(snapshot.username == nil)
        #expect(snapshot.validationStatus == .unknown)
        #expect(try components.keychain.string(forKey: reentrancyRecommendationKey) == nil)
    }

    @Test("disable wins over an older username validation")
    func disableInvalidatesPendingEnable() async throws {
        let components = makeReentrancyService()
        defer {
            removeReentrancyArtifacts(
                queueFileURL: components.queueFileURL,
                defaultsSuiteName: components.defaultsSuiteName
            )
        }

        let enableTask = Task {
            try await components.service.enable(username: "stale-user")
        }
        await components.transport.waitForRequestCount(1)

        await components.service.disable()
        #expect(components.transport.respond(
            to: 0,
            status: 200,
            body: reentrancyUsernameSuccessBody
        ))
        try await enableTask.value

        let snapshot = await components.service.currentSnapshot()
        #expect(!snapshot.isEnabled)
        #expect(snapshot.username == nil)
        #expect(snapshot.validationStatus == .unknown)
    }

    @Test("the newest username validation wins even when it finishes first")
    func newestEnableWinsOutOfOrderCompletion() async throws {
        let components = makeReentrancyService()
        defer {
            removeReentrancyArtifacts(
                queueFileURL: components.queueFileURL,
                defaultsSuiteName: components.defaultsSuiteName
            )
        }

        let oldTask = Task {
            try await components.service.enable(username: "old-user")
        }
        await components.transport.waitForRequestCount(1)

        let newTask = Task {
            try await components.service.enable(username: "new-user")
        }
        await components.transport.waitForRequestCount(2)

        #expect(components.transport.respond(
            to: 1,
            status: 200,
            body: reentrancyUsernameSuccessBody
        ))
        try await newTask.value
        #expect(components.transport.respond(
            to: 0,
            status: 200,
            body: reentrancyUsernameSuccessBody
        ))
        try await oldTask.value

        let snapshot = await components.service.currentSnapshot()
        #expect(snapshot.isEnabled)
        #expect(snapshot.username == "new-user")
        #expect(snapshot.validationStatus == .valid)
        #expect(try components.keychain.string(forKey: reentrancyRecommendationKey) == "new-user")
    }

    @Test("clearing a token wins over an older token validation")
    func clearTokenInvalidatesPendingValidation() async throws {
        let components = makeReentrancyService()
        defer {
            removeReentrancyArtifacts(
                queueFileURL: components.queueFileURL,
                defaultsSuiteName: components.defaultsSuiteName
            )
        }

        let validationTask = Task {
            try await components.service.validateAndSaveScrobblingToken(
                "stale-token",
                rootURL: reentrancyDefaultRoot
            )
        }
        await components.transport.waitForRequestCount(1)

        await components.service.clearScrobblingToken()
        #expect(components.transport.respond(
            to: 0,
            status: 200,
            body: reentrancyTokenSuccessBody(username: "stale-user")
        ))
        try await validationTask.value

        let snapshot = await components.service.scrobblingSnapshot()
        #expect(!snapshot.isEnabled)
        #expect(snapshot.username == nil)
        #expect(snapshot.validationStatus == .unknown)
        #expect(snapshot.serverRootURL == ListenBrainzService.defaultScrobblingServerURL)
        #expect(try components.keychain.string(forKey: reentrancyTokenKey) == nil)
        #expect(try components.keychain.string(forKey: reentrancyScrobblingUsernameKey) == nil)
    }

    @Test("a failed second credential write rolls both keys back to the active account")
    func secondCredentialWriteFailureRestoresPreviousAccount() async throws {
        let components = makeReentrancyService()
        defer {
            removeReentrancyArtifacts(
                queueFileURL: components.queueFileURL,
                defaultsSuiteName: components.defaultsSuiteName
            )
        }
        try await seedPersistedScrobblingAccount(
            token: "old-token",
            username: "old-user",
            into: components
        )
        components.keychain.configure(failingMutationIDs: [1])

        let replacement = Task {
            try await components.service.validateAndSaveScrobblingToken(
                "new-token",
                rootURL: reentrancyDefaultRoot
            )
        }
        await components.transport.waitForRequestCount(1)
        #expect(components.transport.respond(
            to: 0,
            status: 200,
            body: reentrancyTokenSuccessBody(username: "new-user")
        ))
        await #expect(throws: ReentrancyKeychainError.self) {
            try await replacement.value
        }

        #expect(components.keychain.mutations == [
            .store(reentrancyTokenKey),
            .store(reentrancyScrobblingUsernameKey),
            .store(reentrancyTokenKey),
            .store(reentrancyScrobblingUsernameKey)
        ])
        #expect(try components.keychain.string(forKey: reentrancyTokenKey) == "old-token")
        #expect(
            try components.keychain.string(forKey: reentrancyScrobblingUsernameKey)
                == "old-user"
        )

        let snapshot = await components.service.scrobblingSnapshot()
        #expect(snapshot.isEnabled)
        #expect(snapshot.username == "old-user")
        #expect(snapshot.validationStatus == .valid)
        #expect(snapshot.serverRootURL == ListenBrainzService.defaultScrobblingServerURL)
    }

    @Test("a failed rollback quarantines every surviving credential across restart")
    func rollbackFailureCannotReactivatePartialCredentials() async throws {
        let components = makeReentrancyService()
        defer {
            removeReentrancyArtifacts(
                queueFileURL: components.queueFileURL,
                defaultsSuiteName: components.defaultsSuiteName
            )
        }
        try await seedPersistedScrobblingAccount(
            token: "old-token",
            username: "old-user",
            into: components
        )
        // 1: replacement username write fails.
        // 3: username rollback fails.
        // 4 and 6: token purge fails both immediately and during the simulated restart.
        components.keychain.configure(failingMutationIDs: [1, 3, 4, 6])

        let replacement = Task {
            try await components.service.validateAndSaveScrobblingToken(
                "new-token",
                rootURL: reentrancyDefaultRoot
            )
        }
        await components.transport.waitForRequestCount(1)
        #expect(components.transport.respond(
            to: 0,
            status: 200,
            body: reentrancyTokenSuccessBody(username: "new-user")
        ))
        await #expect(throws: ReentrancyKeychainError.self) {
            try await replacement.value
        }

        var snapshot = await components.service.scrobblingSnapshot()
        #expect(!snapshot.isEnabled)
        #expect(snapshot.username == nil)
        #expect(await components.service.pendingListenCount == 0)
        // The simulated Keychain refuses to remove this survivor. It must remain inert.
        #expect(try components.keychain.string(forKey: reentrancyTokenKey) == "old-token")
        #expect(try components.keychain.string(forKey: reentrancyScrobblingUsernameKey) == nil)
        await components.service.enableScrobbling()
        snapshot = await components.service.scrobblingSnapshot()
        #expect(!snapshot.isEnabled)

        let restartedService = ListenBrainzService(
            client: ListenBrainzClient(transport: components.transport),
            keychain: components.keychain,
            userDefaults: UserDefaults(suiteName: components.defaultsSuiteName)!,
            queueFileURL: components.queueFileURL
        )
        await restartedService.loadPersistedState()
        await restartedService.enableScrobbling()

        let restartedSnapshot = await restartedService.scrobblingSnapshot()
        #expect(!restartedSnapshot.isEnabled)
        #expect(restartedSnapshot.username == nil)
        #expect(try components.keychain.string(forKey: reentrancyTokenKey) == "old-token")
        #expect(try components.keychain.string(forKey: reentrancyScrobblingUsernameKey) == nil)
    }

    @Test("clear and disable wait for an in-progress two-key credential store")
    func clearAndDisableWaitForCredentialCommit() async throws {
        let components = makeReentrancyService()
        defer {
            removeReentrancyArtifacts(
                queueFileURL: components.queueFileURL,
                defaultsSuiteName: components.defaultsSuiteName
            )
        }
        try await seedPersistedScrobblingAccount(
            token: "old-token",
            username: "old-user",
            into: components
        )
        components.keychain.configure(suspendingMutationIDs: [1])

        let replacement = Task {
            try await components.service.validateAndSaveScrobblingToken(
                "new-token",
                rootURL: reentrancyDefaultRoot
            )
        }
        await components.transport.waitForRequestCount(1)
        #expect(components.transport.respond(
            to: 0,
            status: 200,
            body: reentrancyTokenSuccessBody(username: "new-user")
        ))
        await components.keychain.waitForMutationCount(2)

        let clear = Task {
            await components.service.clearScrobblingToken()
        }
        let disable = Task {
            await components.service.disableScrobbling()
        }
        while await components.service.credentialMutationWaiterCount < 2 {
            await Task.yield()
        }

        // Neither intent can observe or mutate the half-written pair.
        #expect(components.keychain.mutations.count == 2)
        let duringCommit = await components.service.scrobblingSnapshot()
        #expect(duringCommit.isEnabled)
        #expect(duringCommit.username == "old-user")

        #expect(components.keychain.resumeMutation(1))
        try await replacement.value
        await clear.value
        await disable.value

        #expect(try components.keychain.string(forKey: reentrancyTokenKey) == nil)
        #expect(try components.keychain.string(forKey: reentrancyScrobblingUsernameKey) == nil)
        let finalSnapshot = await components.service.scrobblingSnapshot()
        #expect(!finalSnapshot.isEnabled)
        #expect(finalSnapshot.username == nil)
    }

    @Test("a persisted queue is discarded when a different account loads it")
    func persistedQueueCannotCrossAccountBoundary() async throws {
        let components = makeReentrancyService()
        let replacementDefaultsSuiteName =
            "test.listenbrainz.reentrancy.replacement.\(UUID().uuidString)"
        defer {
            removeReentrancyArtifacts(
                queueFileURL: components.queueFileURL,
                defaultsSuiteName: components.defaultsSuiteName
            )
            UserDefaults.standard.removePersistentDomain(
                forName: replacementDefaultsSuiteName
            )
        }
        try await seedPersistedScrobblingAccount(
            token: "old-token",
            username: "old-user",
            into: components
        )

        let oldSubmission = Task {
            await components.service.notifyScrobbleThreshold(
                song: makeReentrancySong(id: "old-account-song"),
                startDate: Date(timeIntervalSince1970: 1_700_000_030)
            )
        }
        await components.transport.waitForRequestCount(1)
        #expect(components.transport.respond(to: 0, status: 503))
        await oldSubmission.value
        #expect(await components.service.pendingListenCount == 1)
        #expect(FileManager.default.fileExists(atPath: components.queueFileURL.path))

        let replacementKeychain = ReentrancyKeychain()
        try replacementKeychain.seed("new-token", forKey: reentrancyTokenKey)
        try replacementKeychain.seed(
            "new-user",
            forKey: reentrancyScrobblingUsernameKey
        )
        let replacementDefaults = UserDefaults(
            suiteName: replacementDefaultsSuiteName
        )!
        replacementDefaults.set(true, forKey: reentrancyScrobblingEnabledKey)
        replacementDefaults.set(
            ListenBrainzService.defaultScrobblingServerURL,
            forKey: reentrancyScrobblingRootURLKey
        )
        let replacementTransport = ReentrancyTransport()
        let replacementService = ListenBrainzService(
            client: ListenBrainzClient(transport: replacementTransport),
            keychain: replacementKeychain,
            userDefaults: replacementDefaults,
            queueFileURL: components.queueFileURL
        )

        await replacementService.loadPersistedState()

        #expect(await replacementService.pendingListenCount == 0)
        #expect(replacementTransport.requestCount == 0)
        #expect(!FileManager.default.fileExists(atPath: components.queueFileURL.path))
    }

    @Test("a failed submission from the old account cannot enter the new account queue")
    func staleSubmissionFailureDoesNotEnqueueForReplacementAccount() async throws {
        let components = makeReentrancyService()
        defer {
            removeReentrancyArtifacts(
                queueFileURL: components.queueFileURL,
                defaultsSuiteName: components.defaultsSuiteName
            )
        }

        let oldValidation = Task {
            try await components.service.validateAndSaveScrobblingToken(
                "old-token",
                rootURL: reentrancyDefaultRoot
            )
        }
        await components.transport.waitForRequestCount(1)
        #expect(components.transport.respond(
            to: 0,
            status: 200,
            body: reentrancyTokenSuccessBody(username: "old-user")
        ))
        try await oldValidation.value

        let staleSubmission = Task {
            await components.service.notifyScrobbleThreshold(
                song: makeReentrancySong(id: "old-song"),
                startDate: Date(timeIntervalSince1970: 1_700_000_001)
            )
        }
        await components.transport.waitForRequestCount(2)

        let replacement = Task {
            try await components.service.validateAndSaveScrobblingToken(
                "new-token",
                rootURL: reentrancyDefaultRoot
            )
        }
        await components.transport.waitForRequestCount(3)
        #expect(components.transport.respond(
            to: 2,
            status: 200,
            body: reentrancyTokenSuccessBody(username: "new-user")
        ))
        try await replacement.value

        #expect(components.transport.respond(to: 1, status: 503))
        await staleSubmission.value

        #expect(await components.service.pendingListenCount == 0)
        let snapshot = await components.service.scrobblingSnapshot()
        #expect(snapshot.isEnabled)
        #expect(snapshot.username == "new-user")
        #expect(try components.keychain.string(forKey: reentrancyTokenKey) == "new-token")
    }

    @Test("an old successful flush cannot remove listens queued by a replacement account")
    func staleFlushDoesNotDropReplacementAccountQueue() async throws {
        let components = makeReentrancyService()
        defer {
            removeReentrancyArtifacts(
                queueFileURL: components.queueFileURL,
                defaultsSuiteName: components.defaultsSuiteName
            )
        }

        let oldValidation = Task {
            try await components.service.validateAndSaveScrobblingToken(
                "old-token",
                rootURL: reentrancyDefaultRoot
            )
        }
        await components.transport.waitForRequestCount(1)
        #expect(components.transport.respond(
            to: 0,
            status: 200,
            body: reentrancyTokenSuccessBody(username: "old-user")
        ))
        try await oldValidation.value

        let oldListenDate = Date(timeIntervalSince1970: 1_700_000_010)
        let oldSubmission = Task {
            await components.service.notifyScrobbleThreshold(
                song: makeReentrancySong(id: "old-song"),
                startDate: oldListenDate
            )
        }
        await components.transport.waitForRequestCount(2)
        #expect(components.transport.respond(to: 1, status: 503))
        await oldSubmission.value
        #expect(await components.service.pendingListenCount == 1)

        let staleFlush = Task {
            await components.service.flushOfflineQueue()
        }
        await components.transport.waitForRequestCount(3)

        let replacement = Task {
            try await components.service.validateAndSaveScrobblingToken(
                "new-token",
                rootURL: reentrancyDefaultRoot
            )
        }
        await components.transport.waitForRequestCount(4)
        #expect(components.transport.respond(
            to: 3,
            status: 200,
            body: reentrancyTokenSuccessBody(username: "new-user")
        ))
        try await replacement.value
        #expect(await components.service.pendingListenCount == 0)

        let newListenDate = Date(timeIntervalSince1970: 1_700_000_020)
        let newSubmission = Task {
            await components.service.notifyScrobbleThreshold(
                song: makeReentrancySong(id: "new-song"),
                startDate: newListenDate
            )
        }
        await components.transport.waitForRequestCount(5)
        #expect(components.transport.respond(to: 4, status: 503))
        await newSubmission.value
        #expect(await components.service.pendingListenCount == 1)

        #expect(components.transport.respond(to: 2, status: 200))
        await staleFlush.value

        #expect(await components.service.pendingListenCount == 1)
        let queueData = try Data(contentsOf: components.queueFileURL)
        let persisted = try JSONDecoder().decode(PendingListenQueueFile.self, from: queueData)
        #expect(persisted.listens.map(\.listenedAt) == [Int(newListenDate.timeIntervalSince1970)])
    }
}

private func makeReentrancySong(id: String) -> DisplayableSong {
    DisplayableSong(
        id: id,
        title: id,
        artist: "Artist",
        albumId: "album",
        albumName: "Album",
        artistId: "artist",
        genre: nil,
        duration: 180,
        trackNumber: 1,
        isDownloaded: false,
        coverArtId: nil,
        audioFormat: nil,
        replayGainTrackGain: nil,
        replayGainTrackPeak: nil,
        replayGainAlbumGain: nil,
        replayGainAlbumPeak: nil,
        replayGainBaseGain: nil,
        replayGainFallbackGain: nil
    )
}
