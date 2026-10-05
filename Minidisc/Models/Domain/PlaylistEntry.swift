import Foundation

/// Subsonic identifies songs, but a playlist may contain several occurrences of a song.
/// Assign identities before sorting, and retain the entries throughout an editing session.
nonisolated struct PlaylistEntry: Identifiable, Equatable, Sendable {
    struct ID: Hashable, Sendable {
        let songID: String
        let occurrence: Int
    }

    let id: ID
    let sourceIndex: Int
    let song: DisplayableSong

    static func make(_ songs: [DisplayableSong]) -> [PlaylistEntry] {
        appending(songs, to: [])
    }

    static func appending(_ songs: [DisplayableSong], to entries: [PlaylistEntry]) -> [PlaylistEntry] {
        var next: [String: Int] = [:]
        for entry in entries {
            next[entry.song.id] = max(next[entry.song.id, default: 0], entry.id.occurrence + 1)
        }
        return entries + songs.enumerated().map { index, song in
            let occurrence = next[song.id, default: 0]
            next[song.id] = occurrence + 1
            return PlaylistEntry(id: ID(songID: song.id, occurrence: occurrence),
                                 sourceIndex: entries.count + index, song: song)
        }
    }

    /// Retain the selected occurrence when validation removes other songs from the queue.
    static func playbackQueue(requested: [PlaylistEntry], selectedID: ID,
                              available: [DisplayableSong]) -> PreparedPlaybackQueue? {
        let current = Dictionary(make(available).map { ($0.id, $0.song) }, uniquingKeysWith: { first, _ in first })
        let retained = requested.compactMap { entry -> PlaylistEntry? in
            guard let song = current[entry.id] else { return nil }
            return PlaylistEntry(id: entry.id, sourceIndex: entry.sourceIndex, song: song)
        }
        guard let index = retained.firstIndex(where: { $0.id == selectedID }) else { return nil }
        return PreparedPlaybackQueue(tracks: retained.map(\.song), startIndex: index)
    }
}
