import Foundation

nonisolated enum RepeatMode: String, Sendable, Codable, CaseIterable {
    case off
    case one
    case all
}

extension RepeatMode {
    var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }

    var systemImage: String {
        switch self {
        case .off:  return "repeat"
        case .all:  return "repeat"
        case .one:  return "repeat.1"
        }
    }

    /// Spoken state for the repeat toggle.
    var accessibilityValue: LocalizedStringResource {
        switch self {
        case .off: "Off"
        case .all: "All"
        case .one: "One"
        }
    }
}
