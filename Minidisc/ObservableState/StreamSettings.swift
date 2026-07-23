// Minidisc — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import Network
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
    /// Latest connection type from the path monitor. Read on demand, so it needn't be observable.
    @ObservationIgnored private var isCellular = false
    @ObservationIgnored private let monitor = NWPathMonitor()

    var wifiQuality: StreamQuality {
        get {
            access(keyPath: \.wifiQuality)
            return _wifiQuality
        }
        set {
            withMutation(keyPath: \.wifiQuality) { _wifiQuality = newValue }
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.wifiKey)
        }
    }

    var cellularQuality: StreamQuality {
        get {
            access(keyPath: \.cellularQuality)
            return _cellularQuality
        }
        set {
            withMutation(keyPath: \.cellularQuality) { _cellularQuality = newValue }
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.cellularKey)
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

    init() {
        let legacy = UserDefaults.standard.string(forKey: Self.legacyKey)
        let wifiRaw = UserDefaults.standard.string(forKey: Self.wifiKey) ?? legacy
        let cellularRaw = UserDefaults.standard.string(forKey: Self.cellularKey) ?? legacy
        _wifiQuality = StreamQuality(rawValue: wifiRaw ?? "") ?? Self.defaultWifiQuality
        _cellularQuality = StreamQuality(rawValue: cellularRaw ?? "") ?? Self.defaultCellularQuality
        startMonitoring()
    }

    private func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            let cellular = path.usesInterfaceType(.cellular)
            Task { @MainActor [weak self] in self?.isCellular = cellular }
        }
        monitor.start(queue: DispatchQueue(label: "minidisc.network.monitor"))
    }
}
