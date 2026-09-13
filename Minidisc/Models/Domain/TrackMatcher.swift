import Foundation

nonisolated struct TrackDescriptor: Sendable, Equatable, Hashable {
    let title: String
    let artist: String?
    let album: String?

    init(title: String, artist: String? = nil, album: String? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
    }

    var cacheKey: String {
        "\(TrackMatcher.normalise(title))|\(TrackMatcher.normalise(artist ?? ""))"
    }
}

/// Resolves AudioMuse metadata to server IDs when AudioMuse returns its own identifiers.
nonisolated enum TrackMatcher {

    static func normalise(_ text: String) -> String { MoodTagMatcher.normalise(text) }

    /// Requires an artist match when supplied. Without an artist, only an unambiguous title qualifies.
    static func bestMatch(for wanted: TrackDescriptor, among candidates: [TrackDescriptor.Candidate]) -> String? {
        let wantedTitle = normalise(wanted.title)
        guard !wantedTitle.isEmpty else { return nil }

        let titleMatches = candidates.filter { candidate in
            let title = normalise(candidate.title)
            guard !title.isEmpty else { return false }
            // Containment either way absorbs the suffixes servers and taggers add or drop:
            // "Song (Remastered)" against "Song", "Song - Live" against "Song".
            return title == wantedTitle || title.contains(wantedTitle) || wantedTitle.contains(title)
        }
        guard !titleMatches.isEmpty else { return nil }

        guard let wantedArtist = wanted.artist.map(normalise), !wantedArtist.isEmpty else {
            return titleMatches.count == 1 ? titleMatches[0].id : nil
        }

        let artistMatches = titleMatches.filter { candidate in
            let artist = normalise(candidate.artist ?? "")
            guard !artist.isEmpty else { return false }
            return artist == wantedArtist || artist.contains(wantedArtist) || wantedArtist.contains(artist)
        }
        guard !artistMatches.isEmpty else { return nil }

        // Break ties by ID so repeated resolutions select the same track.
        let ranked = artistMatches.sorted { lhs, rhs in
            let lhsExactTitle = normalise(lhs.title) == wantedTitle
            let rhsExactTitle = normalise(rhs.title) == wantedTitle
            if lhsExactTitle != rhsExactTitle { return lhsExactTitle }
            let lhsExactArtist = normalise(lhs.artist ?? "") == wantedArtist
            let rhsExactArtist = normalise(rhs.artist ?? "") == wantedArtist
            if lhsExactArtist != rhsExactArtist { return lhsExactArtist }
            return lhs.id < rhs.id
        }
        return ranked.first?.id
    }
}

extension TrackDescriptor {
    nonisolated struct Candidate: Sendable, Equatable {
        let id: String
        let title: String
        let artist: String?

        init(id: String, title: String, artist: String? = nil) {
            self.id = id
            self.title = title
            self.artist = artist
        }
    }
}
