import Foundation

/// User preference for where lyrics are fetched.
nonisolated enum LyricsSource: String, CaseIterable, Identifiable, Sendable, Codable {
    case automatic = "auto"
    case navidrome
    case lrclib

    var id: String { rawValue }

    var displayName: LocalizedStringResource {
        switch self {
        case .automatic: "Auto"
        case .navidrome: "Navidrome"
        case .lrclib: "LRCLIB"
        }
    }
}

/// Concrete provider that produced a cached lyrics response.
nonisolated enum LyricsProvider: String, Sendable {
    case navidrome
    case lrclib
}
