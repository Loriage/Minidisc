import Foundation

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

nonisolated enum LyricsProvider: String, Sendable {
    case navidrome
    case lrclib
}
