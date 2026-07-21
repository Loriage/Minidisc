// Minidisc — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import Observation

/// User-configurable live-stream quality, persisted in UserDefaults.
/// @Observable so SettingsView updates live. Injected into AppContainer; MediaResolver reads
/// the value via MainActor.run when resolving a stream URL.
@Observable
@MainActor
final class StreamSettings {
    @ObservationIgnored private var _quality: StreamQuality

    var quality: StreamQuality {
        get {
            access(keyPath: \.quality)
            return _quality
        }
        set {
            withMutation(keyPath: \.quality) {
                _quality = newValue
            }
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.qualityKey)
        }
    }

    static let defaultQuality: StreamQuality = .original
    private static let qualityKey = "minidisc.stream.quality"

    init() {
        let raw = UserDefaults.standard.string(forKey: Self.qualityKey)
        self._quality = StreamQuality(rawValue: raw ?? "") ?? Self.defaultQuality
    }
}
