import Foundation
import Testing
@testable import Minidisc

@Suite("Manual offline mode") @MainActor
struct OfflineModeTests {
    private func path(_ online: Bool, generation: UInt64) -> NetworkPathEvent {
        NetworkPathEvent(generation: generation, descriptor: NetworkPathDescriptor(
            isOnline: online, isExpensive: false, isConstrained: false,
            supportsDNS: true, supportsIPv4: true, supportsIPv6: true,
            interfaces: [.wifi], gateways: []
        ))
    }

    @Test func preferenceSurvivesRelaunchAndDoesNotChangeActualReachability() throws {
        let name = "OfflineModeTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let state = ServerState(defaults: defaults)
        #expect(!state.isOfflineModeEnabled)
        state.applyNetworkPath(path(true, generation: 0))
        state.isOfflineModeEnabled = true
        #expect(!state.isOnline && !state.networkPathEvent.isOnline)
        #expect(!state.libraryIndexPreparationSnapshot.automaticRefreshAllowed)
        let restored = ServerState(defaults: defaults)
        #expect(restored.isOfflineModeEnabled && !restored.isOnline)
        restored.applyNetworkPath(path(true, generation: 0))
        #expect(!restored.isOnline)
        restored.isOfflineModeEnabled = false
        #expect(restored.isOnline && restored.networkPathEvent.isOnline)
        #expect(restored.libraryIndexPreparationSnapshot.automaticRefreshAllowed)
    }

    @Test func physicalChangesCannotOverrideOfflineModeAndGenerationsRemainOrdered() {
        let state = ServerState()
        state.applyNetworkPath(path(true, generation: 0))
        state.isOfflineModeEnabled = true
        let first = state.networkPathEvent.generation
        state.applyNetworkPath(path(false, generation: 1))
        state.applyNetworkPath(path(true, generation: 2))
        #expect(!state.isOnline && !state.networkPathEvent.isOnline)
        #expect(state.networkPathEvent.generation == first + 2)
        state.isOfflineModeEnabled = false
        #expect(state.isOnline && state.networkPathEvent.generation == first + 3)
        state.applyNetworkPath(path(false, generation: 3))
        state.isOfflineModeEnabled = true
        state.isOfflineModeEnabled = false
        #expect(!state.isOnline && !state.networkPathEvent.isOnline)
    }
}
