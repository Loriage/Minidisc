import Foundation
import Synchronization

/// Bridges the service, queue and MainActor persistence boundaries. A deletion invalidates
/// work that was already preparing, and blocks replacement work until removal has finished.
nonisolated final class DownloadIntentRegistry: Sendable {
    struct Key: Hashable, Sendable {
        let serverID: UUID
        let owner: DownloadOwner
        var songID: String? = nil
    }

    struct Token: Sendable {
        let id = UUID()
        fileprivate let registry: DownloadIntentRegistry
        fileprivate let key: Key
        fileprivate let generation: UInt64
        fileprivate let revision: UInt64
        var isCurrent: Bool { registry.isCurrent(self) }
        func check() throws {
            try Task.checkCancellation()
            guard isCurrent else { throw CancellationError() }
        }
    }

    private struct State {
        var generation: UInt64 = 0
        var revisions: [Key: UInt64] = [:]
        var removing: [Key: Int] = [:]
        var removingAll = false
    }
    private let state = Mutex(State())

    func capture(_ key: Key) throws -> Token {
        try state.withLock { value in
            guard !value.removingAll, value.removing[key] == nil else { throw CancellationError() }
            return Token(registry: self, key: key, generation: value.generation,
                         revision: value.revisions[key, default: 0])
        }
    }

    private func isCurrent(_ token: Token) -> Bool {
        state.withLock {
            !$0.removingAll && $0.removing[token.key] == nil && token.generation == $0.generation
                && token.revision == $0.revisions[token.key, default: 0]
        }
    }

    func beginRemoval(_ key: Key) {
        state.withLock {
            $0.revisions[key, default: 0] &+= 1
            $0.removing[key, default: 0] += 1
        }
    }

    func endRemoval(_ key: Key) {
        state.withLock {
            if $0.removing[key] == 1 { $0.removing.removeValue(forKey: key) }
            else { $0.removing[key, default: 1] -= 1 }
        }
    }

    func beginRemovingAll() {
        state.withLock { $0.generation &+= 1; $0.removingAll = true }
    }

    func endRemovingAll() { state.withLock { $0.removingAll = false } }
}
