import Foundation
import Network
import OSLog

private nonisolated struct NetworkPathSnapshot: Sendable {
    let isOnline: Bool
    let isExpensive: Bool
    let isCellular: Bool
}

/// Wraps NWPathMonitor and keeps ServerState.isOnline in sync.
/// Start once from the MainActor-owned AppContainer.
@MainActor
final class NetworkMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "app.minidisc.network", qos: .utility)
    private var updateTask: Task<Void, Never>?
    private var updateContinuation: AsyncStream<NetworkPathSnapshot>.Continuation?

    func start(serverState: ServerState, streamSettings: StreamSettings) {
        guard updateTask == nil else { return }
        let channel = AsyncStream<NetworkPathSnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        updateContinuation = channel.continuation
        updateTask = Task { @MainActor in
            for await snapshot in channel.stream {
                guard !Task.isCancelled else { break }
                serverState.isOnline = snapshot.isOnline
                serverState.isExpensive = snapshot.isExpensive
                streamSettings.networkPathDidChange(isCellular: snapshot.isCellular)
            }
        }

        let continuation = channel.continuation
        monitor.pathUpdateHandler = { path in
            continuation.yield(NetworkPathSnapshot(
                isOnline: path.status == .satisfied,
                isExpensive: path.isExpensive,
                isCellular: path.usesInterfaceType(.cellular)
            ))
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
}
