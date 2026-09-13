import Foundation
import Observation

/// Selects server transcoding quality separately for Wi-Fi and cellular connections.
@Observable
@MainActor
final class StreamSettings {
    @ObservationIgnored private var _wifiQuality: StreamQuality
    @ObservationIgnored private var _cellularQuality: StreamQuality
    @ObservationIgnored private let defaults: UserDefaults
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
