import Foundation

/// A retry keeps its original baseline. If the server accepted an append but its response was lost,
/// only missing occurrences are sent again. Existing duplicates and intervening additions survive.
nonisolated struct PlaylistAppendIntent {
    let songs: [DisplayableSong]
    let baselineCounts: [String: Int]

    init(songs: [DisplayableSong], existingIDs: [String]) {
        self.songs = songs
        baselineCounts = Self.counts(existingIDs)
    }

    func remaining(after currentIDs: [String]) -> [DisplayableSong] {
        let current = Self.counts(currentIDs)
        var accepted = current.mapValues { $0 }
        for (id, count) in current { accepted[id] = max(0, count - baselineCounts[id, default: 0]) }
        return songs.filter { song in
            guard accepted[song.id, default: 0] > 0 else { return true }
            accepted[song.id, default: 0] -= 1
            return false
        }
    }

    private static func counts(_ ids: [String]) -> [String: Int] {
        ids.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }
}
