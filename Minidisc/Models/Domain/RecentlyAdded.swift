import Foundation
import SwiftSonic

/// The virtual "Recently Added" playlist: the tracks of the albums most recently added to the library.
///
/// Derived from `getAlbumList2?type=newest` on demand instead of materialised as a server playlist — like
/// `ArtistBestOf` it stays in sync with the library by construction, and exists only inside Minidisc. Subsonic
/// exposes no track-level recency endpoint, so the album list is the only "what's new" signal available.
///
/// Order is the server's album order (newest first) and, within an album, the album's own track order.
/// Re-sorting the flattened list by each track's `created` would interleave albums whose files happened to
/// land on disk out of order — still recent, but no longer playable as the records it came from.
nonisolated enum RecentlyAdded {
    /// How many of the newest albums are scanned for tracks. Each one costs a `getAlbum` round-trip, so this
    /// is what bounds the screen's load time on a home server.
    static let albumsToScan = 25

    /// Ceiling on the assembled list. Box sets run to hundreds of tracks; past this the playlist stops being
    /// "what's new" and turns into a second library.
    static let trackLimit = 300

    /// Flattens per-album track lists back into album order, dropping ids already seen and capping the result.
    ///
    /// Albums arrive out of order (they are fetched concurrently), hence the index each one carries. The
    /// dedupe guards against a server that lists the same file under two albums — a duplicate would otherwise
    /// play twice in a row.
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
