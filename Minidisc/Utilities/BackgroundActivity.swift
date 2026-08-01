import Foundation
import OSLog
import UIKit

/// Asks iOS to keep the app running while a long piece of work finishes after the user leaves.
///
/// Minidisc declares the `audio` background mode, so ANY work runs freely while music plays — which
/// covers Instant Mix, since the seed track starts before the mix is built. The gap is work started
/// with nothing playing: browsing, then backgrounding. Without an assertion the app is suspended
/// within a few seconds and the work simply freezes mid-flight.
///
/// What this buys is a grace period, roughly half a minute — not unlimited time. Anything longer
/// still has to survive being interrupted, which is why the mood sync records its progress per mood
/// rather than per run.
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

    /// Runs `operation` inside a background task assertion.
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
