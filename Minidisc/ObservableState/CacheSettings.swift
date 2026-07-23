// Minidisc — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import Observation

/// User-configurable cache preferences persisted in UserDefaults.
/// @Observable so SettingsView updates live when the user changes settings.
/// Injected into AppContainer; services read values via MainActor.run when needed.
@Observable
@MainActor
final class CacheSettings {
    // MARK: - Storage (observation ignored)

    @ObservationIgnored private var _maxTracks: Int
    @ObservationIgnored private var _cacheFormat: CacheFormat
    @ObservationIgnored private var _cacheOverCellular: Bool
    @ObservationIgnored private var _cacheArtwork: Bool

    // MARK: - Visible properties (manual observation hooks)

    var maxTracks: Int {
        get {
            access(keyPath: \.maxTracks)
            return _maxTracks
        }
        set {
            let clamped = max(Self.minMaxTracks, min(Self.maxMaxTracks, newValue))
            withMutation(keyPath: \.maxTracks) {
                _maxTracks = clamped
            }
            UserDefaults.standard.set(clamped, forKey: Self.maxTracksKey)
        }
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
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.cacheFormatKey)
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
            UserDefaults.standard.set(newValue, forKey: Self.cacheOverCellularKey)
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
            UserDefaults.standard.set(newValue, forKey: Self.cacheArtworkKey)
        }
    }

    // MARK: - Defaults & keys

    static let defaultMaxTracks: Int = 10
    static let minMaxTracks: Int = 1
    static let maxMaxTracks: Int = 10
    static let defaultFormat: CacheFormat = .matchStream
    static let defaultCacheOverCellular: Bool = false
    static let defaultCacheArtwork: Bool = true

    private static let maxTracksKey = "minidisc.cache.maxTracks"
    private static let cacheFormatKey = "minidisc.cache.format"
    private static let cacheOverCellularKey = "minidisc.cache.cellular"
    private static let cacheArtworkKey = "minidisc.cache.artwork"

    // MARK: - Init

    init() {
        let loadedMaxTracks = UserDefaults.standard.integer(forKey: Self.maxTracksKey)
        self._maxTracks = (loadedMaxTracks == 0)
            ? Self.defaultMaxTracks
            : max(Self.minMaxTracks, min(Self.maxMaxTracks, loadedMaxTracks))

        let loadedFormatRaw = UserDefaults.standard.string(forKey: Self.cacheFormatKey)
        self._cacheFormat = CacheFormat(rawValue: loadedFormatRaw ?? "") ?? Self.defaultFormat

        self._cacheOverCellular = UserDefaults.standard.bool(forKey: Self.cacheOverCellularKey)
        // object(forKey:) so the default is true — bool(forKey:) would silently default to false.
        self._cacheArtwork = UserDefaults.standard.object(forKey: Self.cacheArtworkKey) as? Bool ?? Self.defaultCacheArtwork
    }
}
