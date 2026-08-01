import Foundation
import Synchronization

/// A narrow, compiler-checked synchronization boundary for preferences used by
/// service actors.
///
/// `UserDefaults` never escapes this concrete API. Foundation does not declare
/// `UserDefaults` as `Sendable`, so this narrow wrapper supplies the missing
/// conformance while serializing every access through the same mutex.
nonisolated final class LockedUserDefaults: @unchecked Sendable {
    private let storage: UserDefaults
    private let lock = Mutex<Void>(())

    init(_ userDefaults: UserDefaults) {
        storage = userDefaults
    }

    func bool(forKey key: String) -> Bool {
        lock.withLock { _ in storage.bool(forKey: key) }
    }

    func double(forKey key: String) -> Double {
        lock.withLock { _ in storage.double(forKey: key) }
    }

    func integer(forKey key: String) -> Int {
        lock.withLock { _ in storage.integer(forKey: key) }
    }

    func string(forKey key: String) -> String? {
        lock.withLock { _ in storage.string(forKey: key) }
    }

    func set(_ value: Bool, forKey key: String) {
        lock.withLock { _ in storage.set(value, forKey: key) }
    }

    func set(_ value: Double, forKey key: String) {
        lock.withLock { _ in storage.set(value, forKey: key) }
    }

    func set(_ value: Int, forKey key: String) {
        lock.withLock { _ in storage.set(value, forKey: key) }
    }

    func set(_ value: String, forKey key: String) {
        lock.withLock { _ in storage.set(value, forKey: key) }
    }

    func removeObject(forKey key: String) {
        lock.withLock { _ in storage.removeObject(forKey: key) }
    }

    func removeObjects(forKeys keys: [String]) {
        lock.withLock { _ in
            for key in keys {
                storage.removeObject(forKey: key)
            }
        }
    }
}
