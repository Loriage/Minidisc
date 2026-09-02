import Foundation
import SwiftSonic

nonisolated enum AlbumReleaseCategory: Sendable, Equatable {
    case album
    case singleOrEP
}

extension AlbumID3 {
    /// Groups OpenSubsonic release types into the two shelves shown on an artist page.
    nonisolated var minidiscReleaseCategory: AlbumReleaseCategory {
        let isSingleOrEP = (releaseTypes ?? []).contains { releaseType in
            let normalized = releaseType.lowercased()
            let words = normalized.split { !$0.isLetter }.map(String.init)
            return words.contains("single")
                || words.contains("ep")
                || normalized.contains("extended play")
        }
        return isSingleOrEP ? .singleOrEP : .album
    }
}
