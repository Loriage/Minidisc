import Foundation
import SwiftSonic

/// The discography shelf a release belongs to on an artist page.
/// `CaseIterable` order is the order the shelves appear in.
nonisolated enum AlbumReleaseCategory: Sendable, Equatable, CaseIterable {
    case album
    case ep
    case single
    case live
    case compilation
    case other

    var title: LocalizedStringResource {
        switch self {
        case .album: "Albums"
        case .ep: "EPs"
        case .single: "Singles"
        case .live: "Live Albums"
        case .compilation: "Compilations"
        case .other: "Other Releases"
        }
    }

    /// Maps OpenSubsonic (MusicBrainz) release types to a shelf. A release can carry a primary type plus
    /// secondary types (["Album", "Live"]); the secondary type is the more specific, so it wins.
    nonisolated static func category(releaseTypes: [String]?, isCompilation: Bool? = nil) -> AlbumReleaseCategory {
        let words = Set(
            (releaseTypes ?? []).flatMap { type in
                type.lowercased().split { !$0.isLetter }.map(String.init)
            }
        )
        let normalized = (releaseTypes ?? []).map { $0.lowercased() }

        if words.contains("live") { return .live }
        if isCompilation == true || words.contains("compilation") { return .compilation }
        if words.contains("ep") || normalized.contains(where: { $0.contains("extended play") }) { return .ep }
        if words.contains("single") { return .single }
        if !words.isDisjoint(with: otherSecondaryTypes) { return .other }
        return .album
    }

    private static let otherSecondaryTypes: Set<String> = [
        "soundtrack", "remix", "mixtape", "street", "demo", "dj", "spokenword", "interview", "audiobook",
        "audio", "drama", "broadcast", "other"
    ]
}

extension AlbumID3 {
    nonisolated var minidiscReleaseCategory: AlbumReleaseCategory {
        AlbumReleaseCategory.category(releaseTypes: releaseTypes, isCompilation: isCompilation)
    }
}
