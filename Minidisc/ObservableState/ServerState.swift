import Foundation
import Observation

/// Value-only description of a network path that can safely cross executors.
///
/// `NWPath` itself is neither `Sendable` nor suitable for observable application state. The
/// monitor reduces it to the properties that materially affect requests and stream selection.
nonisolated struct NetworkPathDescriptor: Sendable, Equatable {
    struct Interfaces: OptionSet, Sendable {
        let rawValue: UInt8

        static let wifi = Interfaces(rawValue: 1 << 0)
        static let cellular = Interfaces(rawValue: 1 << 1)
        static let wiredEthernet = Interfaces(rawValue: 1 << 2)
        static let other = Interfaces(rawValue: 1 << 3)
    }

    let isOnline: Bool
    let isExpensive: Bool
    let isConstrained: Bool
    let supportsDNS: Bool
    let supportsIPv4: Bool
    let supportsIPv6: Bool
    let interfaces: Interfaces
    let gateways: [String]

    static let unknown = NetworkPathDescriptor(
        isOnline: true,
        isExpensive: false,
        isConstrained: false,
        supportsDNS: true,
        supportsIPv4: true,
        supportsIPv6: true,
        interfaces: [],
        gateways: []
    )

    var isCellular: Bool { interfaces.contains(.cellular) }
}

/// Monotonic network-path event published by `NetworkMonitor`.
///
/// Generation zero is the initial baseline. Recovery work starts only at generation one, so the
/// first reachability callback cannot interrupt session restoration during application launch.
nonisolated struct NetworkPathEvent: Sendable, Equatable {
    let generation: UInt64
    let descriptor: NetworkPathDescriptor

    static let initial = NetworkPathEvent(generation: 0, descriptor: .unknown)

    var isOnline: Bool { descriptor.isOnline }
}

nonisolated struct ServerSnapshot: Sendable, Equatable {
    let id: UUID
    let displayName: String
    let baseURL: String
    let username: String
    let serverVersion: String?
    let audioMuseURL: String?

    init(from config: ServerConfig) {
        self.id = config.id
        self.displayName = config.displayName
        self.baseURL = config.baseURL
        self.username = config.username
        self.serverVersion = config.serverVersion
        self.audioMuseURL = config.audioMuseURL
    }
}

/// The typed state that determines whether a server-backed screen should retry a read.
/// The connection version changes for server switches and credential or endpoint edits.
nonisolated struct ServerAccessSnapshot: Sendable, Hashable {
    let connectionVersion: ServerConnection.Version?
    let isOnline: Bool
}

/// The state that decides whether a potentially large automatic index walk may start.
/// Manual refreshes are intentionally independent from this snapshot.
nonisolated struct LibraryIndexPreparationSnapshot: Sendable, Hashable {
    let connectionVersion: ServerConnection.Version?
    let isOnline: Bool
    let automaticRefreshAllowed: Bool
}

@Observable
@MainActor
final class ServerState {
    var servers: [ServerSnapshot] = []
    var activeServer: ServerSnapshot?
    var activeConnectionVersion: ServerConnection.Version?
    var isConnected: Bool = false
    private let defaults: UserDefaults?
    private var networkIsOnline = true
    private var physicalNetworkPathEvent: NetworkPathEvent = .initial
    private var offlineModeRevision: UInt64 = 0
    var isOfflineModeEnabled: Bool {
        didSet {
            guard oldValue != isOfflineModeEnabled else { return }
            defaults?.set(isOfflineModeEnabled, forKey: "minidisc.offlineMode")
            offlineModeRevision &+= 1
            publishEffectiveNetworkPath()
        }
    }
    var isOnline: Bool {
        get { networkIsOnline && !isOfflineModeEnabled }
        set { networkIsOnline = newValue }
    }

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        isOfflineModeEnabled = defaults?.bool(forKey: "minidisc.offlineMode") ?? false
        if isOfflineModeEnabled { offlineModeRevision = 1 }
        publishEffectiveNetworkPath()
    }
    /// Updated by NetworkMonitor. True when the connection is metered (cellular, hotspot).
    /// Default false — optimistic until the first NWPath update corrects it on launch (~100ms).
    var isExpensive: Bool = false
    /// Coherent path snapshot. Unlike `isOnline`, its generation also changes for a seamless
    /// Wi-Fi ↔ cellular handover where connectivity remains satisfied throughout.
    var networkPathEvent: NetworkPathEvent = .initial
    /// Prevents the optimistic launch defaults from starting a full index walk before
    /// NWPathMonitor identifies a cellular, hotspot, or Low Data Mode connection.
    var hasObservedNetworkPath = false
    // Prevents OnboardingView flash before persisted state is restored on launch.
    var isLoadingPersistedState: Bool = true

    func applyNetworkPath(_ event: NetworkPathEvent) {
        physicalNetworkPathEvent = event
        networkIsOnline = event.isOnline
        isExpensive = event.descriptor.isExpensive
        publishEffectiveNetworkPath()
        hasObservedNetworkPath = true
    }

    private func publishEffectiveNetworkPath() {
        let path = physicalNetworkPathEvent.descriptor
        networkPathEvent = NetworkPathEvent(
            generation: physicalNetworkPathEvent.generation &+ offlineModeRevision,
            descriptor: NetworkPathDescriptor(
                isOnline: isOnline, isExpensive: path.isExpensive, isConstrained: path.isConstrained,
                supportsDNS: path.supportsDNS, supportsIPv4: path.supportsIPv4,
                supportsIPv6: path.supportsIPv6, interfaces: path.interfaces, gateways: path.gateways
            )
        )
    }

    var accessSnapshot: ServerAccessSnapshot {
        ServerAccessSnapshot(connectionVersion: activeConnectionVersion, isOnline: isOnline)
    }

    var libraryIndexPreparationSnapshot: LibraryIndexPreparationSnapshot {
        let path = networkPathEvent.descriptor
        return LibraryIndexPreparationSnapshot(
            connectionVersion: activeConnectionVersion,
            isOnline: isOnline,
            automaticRefreshAllowed: isOnline && hasObservedNetworkPath
                && path.isOnline
                && !path.isExpensive
                && !path.isConstrained
        )
    }
}
