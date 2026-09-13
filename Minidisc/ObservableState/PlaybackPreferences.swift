import Foundation

/// Keep UserDefaults access on MainActor and share initial preferences with PlayerState.
@MainActor
final class PlaybackPreferences {
    static let defaultVolume: Float = 0.7

    private enum Key {
        static let lastVolume = "minidisc.lastVolume"
        static let autoExtendEnabled = "minidisc.player.autoExtendEnabled"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var restoredVolume: Float {
        guard defaults.object(forKey: Key.lastVolume) != nil else {
            return Self.defaultVolume
        }
        return Float(defaults.double(forKey: Key.lastVolume))
    }

    /// Muting must not replace the last audible volume used when playback resumes.
    func storeLastAudibleVolume(_ volume: Float) {
        guard volume > 0 else { return }
        defaults.set(volume, forKey: Key.lastVolume)
    }

    var isAutoExtendEnabled: Bool { defaults.bool(forKey: Key.autoExtendEnabled) }

    func setAutoExtendEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Key.autoExtendEnabled)
    }
}
