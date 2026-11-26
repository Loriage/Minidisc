import Foundation

nonisolated enum ArtworkQuality: String, Codable, CaseIterable, Identifiable, Sendable {
    case standard
    case high
    case original

    var id: String { rawValue }

    var displayName: LocalizedStringResource {
        switch self {
        case .standard: "Standard (600 px)"
        case .high: "High (1,200 px)"
        case .original: "Original resolution"
        }
    }

    var pixels: Int? {
        switch self {
        case .standard: 600
        case .high: 1200
        case .original: nil
        }
    }

    func satisfies(_ requested: Self) -> Bool {
        (pixels ?? Int.max) >= (requested.pixels ?? Int.max)
    }
}
