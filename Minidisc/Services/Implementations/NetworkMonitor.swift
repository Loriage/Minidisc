import Foundation
import Network
import OSLog
import Synchronization

/// Reduces callback-thread `NWPath` values before the buffering AsyncStream boundary.
///
/// Advancing the generation here means a quick Wi-Fi → offline → Wi-Fi sequence still arrives on
/// the MainActor as generation +2 even when `.bufferingNewest(1)` coalesces the middle snapshot.
nonisolated final class NetworkPathEventReducer: Sendable {
    private struct State: Sendable {
        var descriptor: NetworkPathDescriptor?
        var generation: UInt64 = 0
    }

    private let state = Mutex(State())

    func reduce(_ descriptor: NetworkPathDescriptor) -> NetworkPathEvent {
        state.withLock { state in
            if let previous = state.descriptor, previous != descriptor {
                state.generation &+= 1
            }
            state.descriptor = descriptor
            return NetworkPathEvent(generation: state.generation, descriptor: descriptor)
        }
    }
}

/// Wraps NWPathMonitor and keeps ServerState.isOnline in sync.
/// Start once from the MainActor-owned AppContainer.
@MainActor
final class NetworkMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "app.minidisc.network", qos: .utility)
    private let reducer = NetworkPathEventReducer()
    private var updateTask: Task<Void, Never>?
    private var updateContinuation: AsyncStream<NetworkPathEvent>.Continuation?

    func start(
        serverState: ServerState,
        streamSettings: StreamSettings,
        playerService: any PlayerServiceProtocol
    ) {
        guard updateTask == nil else { return }
        let channel = AsyncStream<NetworkPathEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        updateContinuation = channel.continuation
        updateTask = Task { @MainActor in
            for await event in channel.stream {
                guard !Task.isCancelled else { break }
                serverState.isOnline = event.descriptor.isOnline
                serverState.isExpensive = event.descriptor.isExpensive
                streamSettings.networkPathDidChange(isCellular: event.descriptor.isCellular)
                // Publish the coherent event last: observers that wake on its generation then see
                // the matching online/expensive/quality state above.
                serverState.networkPathEvent = event
                // Playback recovery must not depend on a SwiftUI view task being mounted or surviving
                // cancellation. Deliver every post-baseline path transition directly to the actor.
                if event.generation > 0 {
                    await playerService.handleNetworkPathChanged(event)
                }
            }
        }

        let continuation = channel.continuation
        let reducer = reducer
        monitor.pathUpdateHandler = { path in
            continuation.yield(reducer.reduce(Self.descriptor(for: path)))
        }
        monitor.start(queue: queue)
        Logger.network.debug("NetworkMonitor started.")
    }

    func stop() {
        updateContinuation?.finish()
        updateContinuation = nil
        updateTask?.cancel()
        updateTask = nil
        monitor.cancel()
    }

    private nonisolated static func descriptor(for path: NWPath) -> NetworkPathDescriptor {
        var interfaces: NetworkPathDescriptor.Interfaces = []
        if path.usesInterfaceType(.wifi) { interfaces.insert(.wifi) }
        if path.usesInterfaceType(.cellular) { interfaces.insert(.cellular) }
        if path.usesInterfaceType(.wiredEthernet) { interfaces.insert(.wiredEthernet) }
        if path.usesInterfaceType(.other) { interfaces.insert(.other) }

        return NetworkPathDescriptor(
            isOnline: path.status == .satisfied,
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained,
            supportsDNS: path.supportsDNS,
            supportsIPv4: path.supportsIPv4,
            supportsIPv6: path.supportsIPv6,
            interfaces: interfaces,
            gateways: path.gateways.map { String(describing: $0) }.sorted()
        )
    }
}
