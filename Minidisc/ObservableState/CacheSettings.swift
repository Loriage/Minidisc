import Foundation
import Observation

/// User-configurable cache preferences persisted in UserDefaults.
/// @Observable so SettingsView updates live when the user changes settings.
/// Injected into AppContainer; services read values via MainActor.run when needed.
@Observable
@MainActor
final class CacheSettings {
    // MARK: - Storage (observation ignored)

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var _capacityMegabytes: Int
    @ObservationIgnored private var _cacheFormat: CacheFormat
    @ObservationIgnored private var _cacheOverCellular: Bool
    @ObservationIgnored private var _cacheArtwork: Bool

    // MARK: - Visible properties (manual observation hooks)

    var capacityMegabytes: Int {
        get {
            access(keyPath: \.capacityMegabytes)
            return _capacityMegabytes
        }
        set {
            let normalized = Self.normalizedCapacity(newValue)
            withMutation(keyPath: \.capacityMegabytes) {
                _capacityMegabytes = normalized
            }
            defaults.set(normalized, forKey: Self.capacityMegabytesKey)
        }
    }

    var capacityBytes: Int64 {
        Int64(capacityMegabytes) * 1_000_000
    }

    var cacheFormat: CacheFormat {
        get {
            access(keyPath: \.cacheFormat)
            return _cacheFormat
        }
        set {
            withMutation(keyPath: \.cacheFormat) {
                _cacheFormat = newValue
            }
            defaults.set(newValue.rawValue, forKey: Self.cacheFormatKey)
        }
    }

    var cacheOverCellular: Bool {
        get {
            access(keyPath: \.cacheOverCellular)
            return _cacheOverCellular
        }
        set {
            withMutation(keyPath: \.cacheOverCellular) {
                _cacheOverCellular = newValue
            }
            defaults.set(newValue, forKey: Self.cacheOverCellularKey)
        }
    }

    /// Whether cover art fetched from the server is persisted to disk (memory caching always runs).
    var cacheArtwork: Bool {
        get {
            access(keyPath: \.cacheArtwork)
            return _cacheArtwork
        }
        set {
            withMutation(keyPath: \.cacheArtwork) {
                _cacheArtwork = newValue
            }
            defaults.set(newValue, forKey: Self.cacheArtworkKey)
        }
    }

    // MARK: - Defaults & keys

    static let defaultCapacityMegabytes = 512
    static let minCapacityMegabytes = 128
    static let maxCapacityMegabytes = 2_048
    static let capacityStepMegabytes = 128
    static let defaultFormat: CacheFormat = .matchStream
    static let defaultCacheOverCellular: Bool = false
    static let defaultCacheArtwork: Bool = true

    private static let capacityMegabytesKey = "minidisc.cache.capacityMegabytes"
    private static let legacyMaxTracksKey = "minidisc.cache.maxTracks"
    private static let cacheFormatKey = "minidisc.cache.format"
    private static let cacheOverCellularKey = "minidisc.cache.cellular"
    private static let cacheArtworkKey = "minidisc.cache.artwork"

    // MARK: - Init

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if defaults.object(forKey: Self.capacityMegabytesKey) != nil {
            self._capacityMegabytes = Self.normalizedCapacity(
                defaults.integer(forKey: Self.capacityMegabytesKey)
            )
        } else if defaults.object(forKey: Self.legacyMaxTracksKey) != nil {
            // The former count limit had no byte meaning. Sixty-four MB per track keeps the
            // user's relative choice while moving to a predictable storage budget.
            let migratedCapacity = Self.normalizedCapacity(
                defaults.integer(forKey: Self.legacyMaxTracksKey) * 64
            )
            self._capacityMegabytes = migratedCapacity
            defaults.set(migratedCapacity, forKey: Self.capacityMegabytesKey)
        } else {
            self._capacityMegabytes = Self.defaultCapacityMegabytes
        }

        let loadedFormatRaw = defaults.string(forKey: Self.cacheFormatKey)
        self._cacheFormat = CacheFormat(rawValue: loadedFormatRaw ?? "") ?? Self.defaultFormat

        self._cacheOverCellular = defaults.bool(forKey: Self.cacheOverCellularKey)
        // object(forKey:) so the default is true — bool(forKey:) would silently default to false.
        self._cacheArtwork = defaults.object(forKey: Self.cacheArtworkKey) as? Bool ?? Self.defaultCacheArtwork
    }

    private static func normalizedCapacity(_ value: Int) -> Int {
        let clamped = max(minCapacityMegabytes, min(maxCapacityMegabytes, value))
        let rounded = ((clamped + capacityStepMegabytes / 2) / capacityStepMegabytes)
            * capacityStepMegabytes
        return max(minCapacityMegabytes, min(maxCapacityMegabytes, rounded))
    }
}
