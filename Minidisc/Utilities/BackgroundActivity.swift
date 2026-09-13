import Foundation
import OSLog
import UIKit

/// Requests a limited background grace period. Operations must still tolerate suspension
/// and persist progress before the assertion expires.
nonisolated enum BackgroundActivity {

    @MainActor
    private final class Assertion {
        private var identifier: UIBackgroundTaskIdentifier = .invalid
        private var ended = false

        func begin(name: String) {
            identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
                Logger.boot.warning("[BACKGROUND] '\(name, privacy: .public)' ran out of time — suspending")
                self?.end()
            }
        }

        func end() {
            guard !ended else { return }
            ended = true
            guard identifier != .invalid else { return }
            UIApplication.shared.endBackgroundTask(identifier)
            identifier = .invalid
        }
    }

    static func run<T: Sendable>(_ name: String, operation: @Sendable () async -> T) async -> T {
        let assertion = await MainActor.run {
            let assertion = Assertion()
            assertion.begin(name: name)
            return assertion
        }

        return await withTaskCancellationHandler {
            let result = await operation()
            await assertion.end()
            return result
        } onCancel: {
            Task { @MainActor in
                assertion.end()
            }
        }
    }
}
