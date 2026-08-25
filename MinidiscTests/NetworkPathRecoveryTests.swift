import Testing
import AVFAudio
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

    @Test("automatic indexing waits for a known unmetered path")
    @MainActor
    func automaticIndexingPathPolicy() {
        let state = ServerState()
        #expect(!state.libraryIndexPreparationSnapshot.automaticRefreshAllowed)

        state.networkPathEvent = NetworkPathEvent(generation: 0, descriptor: descriptor())
        state.hasObservedNetworkPath = true
        #expect(state.libraryIndexPreparationSnapshot.automaticRefreshAllowed)

        state.networkPathEvent = NetworkPathEvent(
            generation: 1,
            descriptor: descriptor(expensive: true, interfaces: [.cellular])
        )
        #expect(!state.libraryIndexPreparationSnapshot.automaticRefreshAllowed)

        state.networkPathEvent = NetworkPathEvent(
            generation: 2,
            descriptor: descriptor(constrained: true)
        )
        #expect(!state.libraryIndexPreparationSnapshot.automaticRefreshAllowed)
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

@Suite("Playback network recovery retry budget")
struct PlaybackNetworkRecoveryRetryBudgetTests {
    @Test("recovery is bounded to three attempts for one track and path")
    func boundedAttempts() {
        var budget = PlaybackNetworkRecoveryAttemptBudget()

        #expect(budget.beginAttempt(trackID: "track-a", pathGeneration: 4) == 1)
        #expect(budget.beginAttempt(trackID: "track-a", pathGeneration: 4) == 2)
        #expect(budget.beginAttempt(trackID: "track-a", pathGeneration: 4) == 3)
        #expect(!budget.canAttempt(trackID: "track-a", pathGeneration: 4))
        #expect(budget.beginAttempt(trackID: "track-a", pathGeneration: 4) == nil)
    }

    @Test("a new path generation receives a fresh budget")
    func pathChangeResetsBudget() {
        var budget = PlaybackNetworkRecoveryAttemptBudget()
        for _ in 0..<PlaybackNetworkRecoveryAttemptBudget.maximumAttempts {
            _ = budget.beginAttempt(trackID: "track-a", pathGeneration: 4)
        }

        #expect(budget.canAttempt(trackID: "track-a", pathGeneration: 5))
        #expect(budget.beginAttempt(trackID: "track-a", pathGeneration: 5) == 1)
    }

    @Test("a new track receives a fresh budget")
    func trackChangeResetsBudget() {
        var budget = PlaybackNetworkRecoveryAttemptBudget()
        for _ in 0..<PlaybackNetworkRecoveryAttemptBudget.maximumAttempts {
            _ = budget.beginAttempt(trackID: "track-a", pathGeneration: 4)
        }

        #expect(budget.canAttempt(trackID: "track-b", pathGeneration: 4))
        #expect(budget.beginAttempt(trackID: "track-b", pathGeneration: 4) == 1)
    }

    @Test("explicit Play can reset an exhausted budget")
    func explicitReset() {
        var budget = PlaybackNetworkRecoveryAttemptBudget()
        for _ in 0..<PlaybackNetworkRecoveryAttemptBudget.maximumAttempts {
            _ = budget.beginAttempt(trackID: "track-a", pathGeneration: 4)
        }

        budget.reset()

        #expect(budget.attempts == 0)
        #expect(budget.beginAttempt(trackID: "track-a", pathGeneration: 4) == 1)
    }
}

@Suite("Playback handover reassertion")
struct PlaybackHandoverReassertionTests {
    @Test("online Wi-Fi reasserts a remote mid-track playback intent")
    func remoteMidTrack() {
        #expect(PlayerService.shouldReassertPlaybackOnOnlinePath(
            sourceIsRemoteStream: true,
            isOnline: true,
            playbackState: .playing,
            position: 42,
            duration: 180
        ))
    }

    @Test("user pause, offline path, local source and EOF never auto-resume")
    func exclusions() {
        #expect(!PlayerService.shouldReassertPlaybackOnOnlinePath(
            sourceIsRemoteStream: true,
            isOnline: true,
            playbackState: .paused,
            position: 42,
            duration: 180
        ))
        #expect(!PlayerService.shouldReassertPlaybackOnOnlinePath(
            sourceIsRemoteStream: true,
            isOnline: false,
            playbackState: .playing,
            position: 42,
            duration: 180
        ))
        #expect(!PlayerService.shouldReassertPlaybackOnOnlinePath(
            sourceIsRemoteStream: false,
            isOnline: true,
            playbackState: .playing,
            position: 42,
            duration: 180
        ))
        #expect(!PlayerService.shouldReassertPlaybackOnOnlinePath(
            sourceIsRemoteStream: true,
            isOnline: true,
            playbackState: .playing,
            position: 179,
            duration: 180
        ))
    }

    @Test("a rebuilt item is trusted only after its playhead advances")
    func progressValidation() {
        #expect(PlayerService.networkProgressValidationOutcome(
            baseline: 42,
            current: 42.25,
            duration: 180
        ) == .validated)
        #expect(PlayerService.networkProgressValidationOutcome(
            baseline: 42,
            current: 42.05,
            duration: 180
        ) == .retry)
        #expect(PlayerService.networkProgressValidationOutcome(
            baseline: 179,
            current: 179,
            duration: 180
        ) == .deferToEndOfTrack)
    }
}

@Suite("Personal audio route recovery")
struct PersonalAudioRouteRecoveryTests {
    @Test("an ambiguous previous route never manufactures a pause")
    func ambiguousPreviousRoute() {
        #expect(!PlayerService.shouldSuspendForRouteDisconnect(
            previous: [],
            current: [.builtInSpeaker]
        ))
    }

    @Test("falling from AirPods to the speaker suspends playback")
    func airPodsToSpeaker() {
        #expect(PlayerService.shouldSuspendForRouteDisconnect(
            previous: [.bluetoothA2DP],
            current: [.builtInSpeaker]
        ))
    }

    @Test("a personal route that remains available does not pause")
    func personalRouteStillAvailable() {
        #expect(!PlayerService.shouldSuspendForRouteDisconnect(
            previous: [.bluetoothA2DP],
            current: [.bluetoothA2DP]
        ))
    }

    @Test("automatic recovery never resumes on the speaker")
    func neverResumeOnSpeaker() {
        #expect(!PlayerService.canResumeOnPersonalRoute(
            expected: [.bluetoothA2DP],
            current: [.builtInSpeaker]
        ))
        #expect(PlayerService.canResumeOnPersonalRoute(
            expected: [.bluetoothA2DP],
            current: [.bluetoothA2DP]
        ))
    }
}
