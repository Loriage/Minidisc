// Minidisc — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

/// Which low-level audio engine drives playback.
///
/// `.avPlayer` (default) drives AVFoundation's `AVPlayer`, so decoding runs on Apple's hardware path —
/// bit-perfect lossless without the software-decode crackle — with native format coverage and system
/// integration. `.audioStreaming` is the older software-decoding progressive streamer, kept as a
/// fallback. The engine is picked when `PlayerService` is constructed, so a change needs a restart.
nonisolated enum PlaybackEngine: String, CaseIterable, Identifiable, Sendable {
    case audioStreaming
    case avPlayer

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .audioStreaming: return "AudioStreaming"
        case .avPlayer:       return "AVPlayer (System)"
        }
    }
}
