import Testing
@testable import Minidisc

@Suite("Network path generation")
struct NetworkPathGenerationTests {
    private func descriptor(
        online: Bool = true,
        expensive: Bool = false,
        constrained: Bool = false,
        interfaces: NetworkPathDescriptor.Interfaces = [.wifi],
        supportsDNS: Bool = true,
        supportsIPv4: Bool = true,
        supportsIPv6: Bool = true,
        gateways: [String] = ["gateway-a"]
    ) -> NetworkPathDescriptor {
        NetworkPathDescriptor(
            isOnline: online,
            isExpensive: expensive,
            isConstrained: constrained,
            supportsDNS: supportsDNS,
            supportsIPv4: supportsIPv4,
            supportsIPv6: supportsIPv6,
            interfaces: interfaces,
            gateways: gateways
        )
    }

    @Test("first snapshot establishes generation zero")
    func initialBaseline() {
        let reducer = NetworkPathEventReducer()
        let event = reducer.reduce(descriptor())

        #expect(event.generation == 0)
        #expect(event.isOnline)
    }

    @Test("identical snapshots do not create a path change")
    func duplicateSnapshot() {
        let reducer = NetworkPathEventReducer()
        let path = descriptor()

        #expect(reducer.reduce(path).generation == 0)
        #expect(reducer.reduce(path).generation == 0)
    }

    @Test("satisfied Wi-Fi to satisfied cellular is observable")
    func wifiToCellular() {
        let reducer = NetworkPathEventReducer()
        _ = reducer.reduce(descriptor(interfaces: [.wifi]))

        let cellular = reducer.reduce(descriptor(
            expensive: true,
            interfaces: [.cellular],
            gateways: ["gateway-cellular"]
        ))

        #expect(cellular.generation == 1)
        #expect(cellular.isOnline)
        #expect(cellular.descriptor.isCellular)
    }

    @Test("generation preserves rapid transitions before newest-only delivery")
    func rapidOfflineRoundTrip() {
        let reducer = NetworkPathEventReducer()
        let wifi = descriptor()
        _ = reducer.reduce(wifi)
        _ = reducer.reduce(descriptor(
            online: false,
            interfaces: [],
            supportsDNS: false,
            supportsIPv4: false,
            supportsIPv6: false,
            gateways: []
        ))

        let final = reducer.reduce(wifi)

        #expect(final.generation == 2)
        #expect(final.isOnline)
    }

    @Test("same-interface gateway changes are observable")
    func gatewayChange() {
        let reducer = NetworkPathEventReducer()
        _ = reducer.reduce(descriptor(gateways: ["gateway-a"]))

        #expect(reducer.reduce(descriptor(gateways: ["gateway-b"])).generation == 1)
    }

    @Test("cost, constraint and address-family changes are observable")
    func pathCapabilitiesChange() {
        let reducer = NetworkPathEventReducer()
        _ = reducer.reduce(descriptor())
        #expect(reducer.reduce(descriptor(expensive: true)).generation == 1)
        #expect(reducer.reduce(descriptor(expensive: true, constrained: true)).generation == 2)
        #expect(reducer.reduce(descriptor(
            expensive: true,
            constrained: true,
            supportsIPv6: false
        )).generation == 3)
    }
}

@Suite("Playback network recovery policy")
struct PlaybackNetworkRecoveryPolicyTests {
    @Test("local sources never rebuild for a network event", arguments: [
        PlaybackState.playing,
        PlaybackState.paused,
        PlaybackState.error(.timeout),
    ])
    func localSource(state: PlaybackState) {
        #expect(PlayerService.networkRecoveryAction(
            sourceIsRemoteStream: false,
            isOnline: true,
            playbackState: state
        ) == .none)
    }

    @Test("offline remote playback waits for explicit resume", arguments: [
        PlaybackState.playing,
        PlaybackState.paused,
        PlaybackState.error(.timeout),
    ])
    func offlineRemoteSource(state: PlaybackState) {
        #expect(PlayerService.networkRecoveryAction(
            sourceIsRemoteStream: true,
            isOnline: false,
            playbackState: state
        ) == .reloadOnResume)
    }

    @Test("paused remote playback never auto-resumes")
    func pausedRemoteSource() {
        #expect(PlayerService.networkRecoveryAction(
            sourceIsRemoteStream: true,
            isOnline: true,
            playbackState: .paused
        ) == .reloadOnResume)
    }

    @Test("active or failed remote playback arms bounded recovery", arguments: [
        PlaybackState.playing,
        PlaybackState.error(.timeout),
    ])
    func activeRemoteSource(state: PlaybackState) {
        #expect(PlayerService.networkRecoveryAction(
            sourceIsRemoteStream: true,
            isOnline: true,
            playbackState: state
        ) == .armAutomaticRecovery)
    }
}
