import Foundation
import SwiftSonic

/// Subsonic exposes recency by album, not track. Preserve server album order and
/// each album’s track order rather than interleaving tracks by file creation date.
nonisolated enum RecentlyAdded {
    /// How many of the newest albums are scanned for tracks. Each one costs a `getAlbum` round-trip, so this
    /// is what bounds the screen's load time on a home server.
    static let albumsToScan = 25

    static let trackLimit = 300

    /// Restores album order after concurrent fetches and removes duplicate track IDs.
    static func tracks(from albums: [(index: Int, songs: [Song])], limit: Int = trackLimit) -> [Song] {
        guard limit > 0 else { return [] }
        var seen = Set<String>()
        var ordered: [Song] = []
        for album in albums.sorted(by: { $0.index < $1.index }) {
            for song in album.songs where seen.insert(song.id).inserted {
                ordered.append(song)
                if ordered.count == limit { return ordered }
            }
        }
        return ordered
    }
}
