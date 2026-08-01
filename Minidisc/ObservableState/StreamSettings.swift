import Foundation
import Observation

/// User-configurable live-stream quality, split by the current network so cellular data can stay
/// light while Wi-Fi keeps the original file. The server does the transcode (Subsonic `maxBitRate` /
/// `format`), so the app only picks a tier. Persisted in UserDefaults; `@Observable` so Settings
/// updates live. MediaResolver reads `currentQuality` at stream time via `MainActor.run`.
@Observable
@MainActor
final class StreamSettings {
    @ObservationIgnored private var _wifiQuality: StreamQuality
    @ObservationIgnored private var _cellularQuality: StreamQuality
    @ObservationIgnored private let defaults: UserDefaults
    /// Latest connection type from the path monitor. Read on demand, so it needn't be observable.
    @ObservationIgnored private var isCellular = false

    var wifiQuality: StreamQuality {
        get {
            access(keyPath: \.wifiQuality)
            return _wifiQuality
        }
        set {
            withMutation(keyPath: \.wifiQuality) { _wifiQuality = newValue }
            defaults.set(newValue.rawValue, forKey: Self.wifiKey)
        }
    }

    var cellularQuality: StreamQuality {
        get {
            access(keyPath: \.cellularQuality)
            return _cellularQuality
        }
        set {
            withMutation(keyPath: \.cellularQuality) { _cellularQuality = newValue }
            defaults.set(newValue.rawValue, forKey: Self.cellularKey)
        }
    }

    /// The tier to stream at right now, based on the active connection.
    var currentQuality: StreamQuality { isCellular ? cellularQuality : wifiQuality }

    static let defaultWifiQuality: StreamQuality = .original
    static let defaultCellularQuality: StreamQuality = .mp3_192

    private static let wifiKey = "minidisc.stream.wifiQuality"
    private static let cellularKey = "minidisc.stream.cellularQuality"
    /// Pre-split single-quality key; used to seed both tiers on upgrade.
    private static let legacyKey = "minidisc.stream.quality"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let legacy = defaults.string(forKey: Self.legacyKey)
        let wifiRaw = defaults.string(forKey: Self.wifiKey) ?? legacy
        let cellularRaw = defaults.string(forKey: Self.cellularKey) ?? legacy
        _wifiQuality = StreamQuality(rawValue: wifiRaw ?? "") ?? Self.defaultWifiQuality
        _cellularQuality = StreamQuality(rawValue: cellularRaw ?? "") ?? Self.defaultCellularQuality
    }

    /// Fed by the app-wide NetworkMonitor so connectivity is observed by a single system monitor.
    func networkPathDidChange(isCellular: Bool) {
        self.isCellular = isCellular
    }
}
