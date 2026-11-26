import Foundation

nonisolated enum StreamQuality: String, CaseIterable, Identifiable, Sendable {
    case original
    case mp3_320
    case mp3_192
    case opus_192
    case opus_128

    var id: String { rawValue }

    var displayName: LocalizedStringResource {
        switch self {
        case .original: return "Original"
        case .mp3_320:  return "MP3 320 kbps"
        case .mp3_192:  return "MP3 192 kbps"
        case .opus_192: return "Opus 192 kbps"
        case .opus_128: return "Opus 128 kbps"
        }
    }

    /// `raw` explicitly bypasses the server's per-player transcoding defaults.
    var subsonicFormat: String? {
        switch self {
        case .original: return "raw"
        case .mp3_320, .mp3_192: return "mp3"
        case .opus_192, .opus_128: return "opus"
        }
    }

    /// Subsonic `maxBitRate` query param (kbps). `nil` = no bitrate constraint.
    var subsonicMaxBitRate: Int? {
        switch self {
        case .original: return nil
        case .mp3_320:  return 320
        case .mp3_192:  return 192
        case .opus_192: return 192
        case .opus_128: return 128
        }
    }
}
