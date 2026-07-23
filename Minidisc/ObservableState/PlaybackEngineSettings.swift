// Minidisc — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import Observation

/// The user's chosen playback engine, persisted in UserDefaults. `@Observable` so Settings updates
/// live. Read once by `AppContainer` when it builds `PlayerService`, so a change applies on restart.
@Observable
@MainActor
final class PlaybackEngineSettings {
    @ObservationIgnored private var _engine: PlaybackEngine

    var engine: PlaybackEngine {
        get {
            access(keyPath: \.engine)
            return _engine
        }
        set {
            withMutation(keyPath: \.engine) { _engine = newValue }
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.key)
        }
    }

    static let defaultEngine: PlaybackEngine = .avPlayer
    private static let key = "minidisc.playback.engine"

    init() {
        let raw = UserDefaults.standard.string(forKey: Self.key)
        self._engine = PlaybackEngine(rawValue: raw ?? "") ?? Self.defaultEngine
    }
}
