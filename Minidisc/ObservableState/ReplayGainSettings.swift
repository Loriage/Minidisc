import Foundation
import Observation

/// Which gain tag to prefer when computing ReplayGain.
nonisolated enum ReplayGainMode: String, CaseIterable, Sendable, Codable {
    case track
    case album
}

/// Snapshot of ReplayGain settings that can be passed across actor boundaries.
/// Captured from ReplayGainSettings on the MainActor before crossing into another actor.
nonisolated struct ReplayGainConfig: Sendable {
    let enabled: Bool
    let mode: ReplayGainMode
    let preAmp: Double
    let preventClipping: Bool
}

/// User-configurable ReplayGain preferences persisted in UserDefaults.
/// @Observable so SettingsView updates live when the user changes settings.
/// Injected into AppContainer; services capture a ReplayGainConfig snapshot via MainActor.run.
@Observable
@MainActor
final class ReplayGainSettings {
    // MARK: - Storage (observation ignored)

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var _enabled: Bool
    @ObservationIgnored private var _mode: ReplayGainMode
    @ObservationIgnored private var _preAmp: Double
    @ObservationIgnored private var _preventClipping: Bool

    // MARK: - Visible properties (manual observation hooks)

    var enabled: Bool {
        get {
            access(keyPath: \.enabled)
            return _enabled
        }
        set {
            withMutation(keyPath: \.enabled) {
                _enabled = newValue
            }
            defaults.set(newValue, forKey: Self.enabledKey)
        }
    }

    var mode: ReplayGainMode {
        get {
            access(keyPath: \.mode)
            return _mode
        }
        set {
            withMutation(keyPath: \.mode) {
                _mode = newValue
            }
            defaults.set(newValue.rawValue, forKey: Self.modeKey)
        }
    }

    var preAmp: Double {
        get {
            access(keyPath: \.preAmp)
            return _preAmp
        }
        set {
            let clamped = max(Self.minPreAmp, min(Self.maxPreAmp, newValue))
            withMutation(keyPath: \.preAmp) {
                _preAmp = clamped
            }
            defaults.set(clamped, forKey: Self.preAmpKey)
        }
    }

    var preventClipping: Bool {
        get {
            access(keyPath: \.preventClipping)
            return _preventClipping
        }
        set {
            withMutation(keyPath: \.preventClipping) {
                _preventClipping = newValue
            }
            defaults.set(newValue, forKey: Self.preventClippingKey)
        }
    }

    // MARK: - Defaults, bounds & keys

    static let defaultEnabled: Bool = false
    static let defaultMode: ReplayGainMode = .track
    static let defaultPreAmp: Double = 0
    static let defaultPreventClipping: Bool = true
    static let minPreAmp: Double = -15
    static let maxPreAmp: Double = 15

    private static let enabledKey = "minidisc.replayGain.enabled"
    private static let modeKey = "minidisc.replayGain.mode"
    private static let preAmpKey = "minidisc.replayGain.preAmp"
    private static let preventClippingKey = "minidisc.replayGain.preventClipping"

    // MARK: - Derived

    /// Captures a sendable snapshot for crossing into actor-isolated code.
    var config: ReplayGainConfig {
        ReplayGainConfig(enabled: _enabled, mode: _mode, preAmp: _preAmp, preventClipping: _preventClipping)
    }

    // MARK: - Init

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        _enabled = defaults.bool(forKey: Self.enabledKey)

        let modeRaw = defaults.string(forKey: Self.modeKey)
        _mode = ReplayGainMode(rawValue: modeRaw ?? "") ?? Self.defaultMode

        if defaults.object(forKey: Self.preAmpKey) != nil {
            let stored = defaults.double(forKey: Self.preAmpKey)
            _preAmp = max(Self.minPreAmp, min(Self.maxPreAmp, stored))
        } else {
            _preAmp = Self.defaultPreAmp
        }

        if defaults.object(forKey: Self.preventClippingKey) != nil {
            _preventClipping = defaults.bool(forKey: Self.preventClippingKey)
        } else {
            _preventClipping = Self.defaultPreventClipping
        }
    }
}
