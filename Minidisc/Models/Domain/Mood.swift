import Foundation

/// AudioMuse CLAP queries remain in English; only the user-facing titles are localized.
nonisolated enum Mood: String, CaseIterable, Sendable, Identifiable {
    case night
    case energetic
    case workout
    case chill
    case focus

    var id: String { rawValue }

    var query: String {
        switch self {
        case .night:     return "late night calm atmospheric"
        case .energetic: return "energetic upbeat high energy"
        case .workout:   return "intense driving workout rhythm"
        case .chill:     return "relaxed mellow laid back"
        case .focus:     return "focus instrumental background"
        }
    }

    var title: String.LocalizationValue {
        switch self {
        case .night:     return "Night"
        case .energetic: return "Energetic"
        case .workout:   return "Workout"
        case .chill:     return "Chill"
        case .focus:     return "Focus"
        }
    }

    var symbolName: String {
        switch self {
        case .night:     return "moon.stars"
        case .energetic: return "bolt"
        case .workout:   return "figure.run"
        case .chill:     return "leaf"
        case .focus:     return "headphones"
        }
    }

    /// Name of the server-side playlist backing this mood. Prefixed so the five are recognisable
    /// among the user's own playlists, and so `fetchMoodPlaylists` can find them again by name.
    var playlistName: String { "\(Self.playlistPrefix)\(rawValue.capitalized)" }

    static let playlistPrefix = "Minidisc · "

    static let trackCount = 75
}
