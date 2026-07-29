import SwiftUI

extension Mood {
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
