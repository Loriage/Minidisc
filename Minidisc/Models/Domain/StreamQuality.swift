import Foundation

/// Original audio or server-transcoded MP3. MP3 supports progressive playback without
/// requiring container metadata at the end of the stream.
nonisolated enum StreamQuality: String, CaseIterable, Identifiable, Sendable {
    case original
    case mp3_320
    case mp3_192

    var id: String { rawValue }

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
