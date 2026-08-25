import Foundation
import Observation

/// Sendable snapshot of crossfade settings for crossing actor boundaries.
/// Captured from CrossfadeSettings on the MainActor before passing into PlayerService.
nonisolated struct CrossfadeConfig: Sendable {
    let duration: Double
    let disableForGapless: Bool
}

/// User-configurable crossfade preferences persisted in UserDefaults.
/// @Observable so SettingsView updates live when the user changes settings.
/// Injected into AppContainer; services capture a CrossfadeConfig snapshot via MainActor.run.
@Observable
@MainActor
final class CrossfadeSettings {
    // MARK: - Storage (observation ignored)

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var _duration: Double
    @ObservationIgnored private var _disableForGapless: Bool

    // MARK: - Visible properties (manual observation hooks)

    var duration: Double {
        get {
            access(keyPath: \.duration)
            return _duration
        }
        set {
            let clamped = max(Self.minDuration, min(Self.maxDuration, newValue))
            withMutation(keyPath: \.duration) {
                _duration = clamped
            }
            defaults.set(clamped, forKey: Self.durationKey)
        }
    }

    var disableForGapless: Bool {
        get {
            access(keyPath: \.disableForGapless)
            return _disableForGapless
        }
        set {
            withMutation(keyPath: \.disableForGapless) {
                _disableForGapless = newValue
            }
            defaults.set(newValue, forKey: Self.disableForGaplessKey)
        }
    }

    // MARK: - Defaults, bounds & keys

    static let defaultDuration: Double = 0
    static let minDuration: Double = 0
    static let maxDuration: Double = 12

    private static let durationKey = "minidisc.crossfade.duration"
    private static let disableForGaplessKey = "minidisc.crossfade.disableForGapless"

    // MARK: - Derived

    /// Captures a sendable snapshot for crossing into actor-isolated code.
    var config: CrossfadeConfig {
        CrossfadeConfig(duration: _duration, disableForGapless: _disableForGapless)
    }

    // MARK: - Init

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: Self.durationKey) != nil {
            let stored = defaults.double(forKey: Self.durationKey)
            _duration = max(Self.minDuration, min(Self.maxDuration, stored))
        } else {
            _duration = Self.defaultDuration
        }
        // Default true: gapless albums should not be interrupted by a crossfade.
        if defaults.object(forKey: Self.disableForGaplessKey) != nil {
            _disableForGapless = defaults.bool(forKey: Self.disableForGaplessKey)
        } else {
            _disableForGapless = true
        }
    }
}
