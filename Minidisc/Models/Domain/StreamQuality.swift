// Minidisc — Music client for Subsonic/OpenSubsonic servers
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

/// Quality of the LIVE stream fetched from the server for playback.
///
/// `.original` streams the untouched file (lossless when the source is lossless) — the default,
/// so nothing changes for users who want bit-perfect playback. The transcoded options ask the
/// server to re-encode to a lighter codec, which slashes on-device decode cost: lossless (FLAC)
/// decoding is CPU-heavy and can miss its real-time deadline during a system spike (e.g. taking a
/// screenshot), producing an audible crackle.
///
/// Only MP3 transcodes are offered: a raw byte stream that streams progressively through any
/// engine and proxy chain without container quirks.
nonisolated enum StreamQuality: String, CaseIterable, Identifiable, Sendable {
    case original
    case mp3_320
    case mp3_192

    var id: String { rawValue }

    /// Display label for the Settings picker.
    var displayName: String {
        switch self {
        case .original: return "Original"
        case .mp3_320:  return "MP3 320 kbps"
        case .mp3_192:  return "MP3 192 kbps"
        }
    }

    /// Subsonic `format` query param. `nil` = no override (server serves the original file).
    var subsonicFormat: String? {
        switch self {
        case .original: return nil
        case .mp3_320, .mp3_192: return "mp3"
        }
    }

    /// Subsonic `maxBitRate` query param (kbps). `nil` = no bitrate constraint.
    var subsonicMaxBitRate: Int? {
        switch self {
        case .original: return nil
        case .mp3_320:  return 320
        case .mp3_192:  return 192
        }
    }
}
