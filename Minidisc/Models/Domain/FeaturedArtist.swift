import Foundation

/// Featured artists require a server ID for navigation.
struct FeaturedArtist: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let coverArtId: String?

    /// Top artists by track count in the playlist, capped at `limit`. Ties break by first appearance.
    /// Tracks without an `artistId` (or with an empty name) are skipped — they can't be navigated to.
    static func from(_ songs: [DisplayableSong], limit: Int = 6) -> [FeaturedArtist] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        var names: [String: String] = [:]
        var covers: [String: String?] = [:]
        for song in songs {
            guard let artistId = song.artistId,
                  let artist = song.artist, !artist.isEmpty else { continue }
            if counts[artistId] == nil {
                order.append(artistId)
                names[artistId] = artist
                covers[artistId] = song.coverArtId
            }
            counts[artistId, default: 0] += 1
        }
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
        return order
            .sorted { lhs, rhs in
                let cl = counts[lhs] ?? 0, cr = counts[rhs] ?? 0
                if cl != cr { return cl > cr }
                return (rank[lhs] ?? 0) < (rank[rhs] ?? 0)
            }
            .prefix(limit)
            .map { FeaturedArtist(id: $0, name: names[$0] ?? "", coverArtId: covers[$0] ?? nil) }
    }
}
