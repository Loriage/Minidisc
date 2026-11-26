import Testing
import Foundation
@testable import Minidisc

@MainActor
private final class VMTransport: ListenBrainzTransport {
    private var queue: [(Data, HTTPURLResponse)] = []

    func enqueue(status: Int, for username: String = "user") {
        let body = status == 200 ? Data(#"{"payload":{"count":0}}"#.utf8) : Data()
        let resp = HTTPURLResponse(
            url: URL(string: "https://api.listenbrainz.org/1/user/\(username)")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
        queue.append((body, resp))
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard !queue.isEmpty else { throw URLError(.timedOut) }
        return queue.removeFirst()
    }
}

@MainActor
private final class VMKeychain: KeychainServiceProtocol {
    private var storage: [String: Data] = [:]

    func store<T: Codable & Sendable>(_ value: T, forKey key: String) async throws {
        storage[key] = try JSONEncoder().encode(value)
    }

    func retrieve<T: Codable & Sendable>(_ type: T.Type, forKey key: String) async throws -> T? {
        guard let data = storage[key] else { return nil }
        return try JSONDecoder().decode(type, from: data)
    }

    func delete(forKey key: String) async throws {
        storage[key] = nil
    }
}

@MainActor
private func makeComponents() -> (ListenBrainzSettingsViewModel, VMTransport, String) {
    let transport = VMTransport()
    let keychain = VMKeychain()
    let defaultsSuiteName = "test.vmtest.\(UUID().uuidString)"
    let client = ListenBrainzClient(transport: transport)
    let service = ListenBrainzService(
        client: client,
        keychain: keychain,
        userDefaults: UserDefaults(suiteName: defaultsSuiteName)!
    )
    let vm = ListenBrainzSettingsViewModel(service: service)
    return (vm, transport, defaultsSuiteName)
}

@Suite("ListenBrainzSettingsViewModel")
struct ListenBrainzSettingsViewModelTests {

    @Test("a dotted username passes input validation and connects without changing the account name")
    @MainActor func dottedUsernameConnects() async {
        let (vm, transport, defaultsSuiteName) = makeComponents()
        defer { UserDefaults.standard.removePersistentDomain(forName: defaultsSuiteName) }
        transport.enqueue(status: 200)

        vm.usernameInput = "bad user"
        vm.validateUsernameInputLocally()
        #expect(vm.usernameInputValidationError != nil)

        vm.usernameInput = "Test.User_123-name"
        vm.validateUsernameInputLocally()
        #expect(vm.usernameInputValidationError == nil)

        await vm.connect()
        #expect(vm.snapshot.isEnabled)
        #expect(vm.snapshot.username == "Test.User_123-name")
        #expect(vm.userFacingError == nil)
        #expect(!vm.isProcessing)
    }

    @Test("empty input does not set validation error")
    @MainActor func emptyInputNoError() {
        let (vm, _, _) = makeComponents()

        vm.usernameInput = ""
        vm.validateUsernameInputLocally()

        #expect(vm.usernameInputValidationError == nil)
    }

    @Test("username with space sets validation error")
    @MainActor func usernameWithSpaceSetsError() {
        let (vm, _, _) = makeComponents()

        vm.usernameInput = "bad user"
        vm.validateUsernameInputLocally()

        #expect(vm.usernameInputValidationError != nil)
    }

    @Test("connect with 404 sets userFacingError and leaves disabled")
    @MainActor func connectUserNotFound() async {
        let (vm, transport, _) = makeComponents()
        transport.enqueue(status: 404)

        vm.usernameInput = "CANARY_USER_DO_NOT_LEAK_42"
        await vm.connect()

        #expect(vm.userFacingError != nil)
        #expect(vm.userFacingError?.contains(vm.usernameInput) == false)
        #expect(vm.snapshot.isEnabled == false)
        #expect(vm.isProcessing == false)
    }

    @Test("disconnect disables after a successful connect")
    @MainActor func disconnectDisables() async {
        let (vm, transport, _) = makeComponents()
        transport.enqueue(status: 200)

        vm.usernameInput = "user"
        await vm.connect()
        await vm.disconnect()

        #expect(vm.snapshot.isEnabled == false)
        #expect(vm.isProcessing == false)
    }

    @Test("resetCredentials wipes username and snapshot")
    @MainActor func resetCredentialsClearsState() async {
        let (vm, transport, _) = makeComponents()
        transport.enqueue(status: 200)

        vm.usernameInput = "user"
        await vm.connect()
        await vm.resetCredentials()

        #expect(vm.usernameInput == "")
        #expect(vm.snapshot.username == nil)
        #expect(vm.snapshot.isEnabled == false)
        #expect(vm.isProcessing == false)
    }

    @Test("userFacingError never exposes canary username (500)")
    @MainActor func canaryNotInHttpError() async throws {
        let canary = "CANARY_USER_DO_NOT_LEAK_42"
        let (vm, transport, _) = makeComponents()
        transport.enqueue(status: 500, for: canary)

        vm.usernameInput = canary
        await vm.connect()

        let error = try #require(vm.userFacingError)
        #expect(!error.contains(canary))
    }
}
