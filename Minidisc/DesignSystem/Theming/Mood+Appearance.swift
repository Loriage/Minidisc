import SwiftUI

/// Visual identity of each mood, in one place so the generated playlist cover and anything else
/// showing a mood agree on it.
extension Mood {
    /// Cover generated for this mood's server playlist: a mesh preset each, picked to match the mood and
    /// to keep the five apart at thumbnail size, where close colours are unreadable.
    var gradientSpec: PlaylistGradientSpec {
        let shape: PlaylistGradientShape
        switch self {
        case .night:     shape = .aurora
        case .energetic: shape = .prism
        case .workout:   shape = .ember
        case .chill:     shape = .lagoon
        case .focus:     shape = .sunset
        }
        return .neutral(shape: shape)
    }
}
