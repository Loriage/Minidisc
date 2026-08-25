import Foundation
import Observation

/// Persisted lyrics source preference used by the player and Settings.
@Observable
@MainActor
final class LyricsSettings {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var _source: LyricsSource

    var source: LyricsSource {
        get {
            access(keyPath: \.source)
            return _source
        }
        set {
            withMutation(keyPath: \.source) {
                _source = newValue
            }
            defaults.set(newValue.rawValue, forKey: Self.sourceKey)
        }
    }

    static let defaultSource: LyricsSource = .automatic
    private static let sourceKey = "minidisc.lyrics.source"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.string(forKey: Self.sourceKey)
        _source = LyricsSource(rawValue: stored ?? "") ?? Self.defaultSource
    }
}
