import Foundation
import SwiftSonic

/// Loads the tracks of several albums for "play this group" actions, five requests at a time,
/// and returns them in the albums' order. Albums that fail to load are skipped.
nonisolated enum AlbumTrackLoader {
    static let maxConcurrentRequests = 5

    static func tracks(for albums: [AlbumID3], library: any AlbumBrowsing) async -> [DisplayableSong] {
        var byIndex: [Int: [DisplayableSong]] = [:]
        await withTaskGroup(of: (Int, [DisplayableSong]).self) { group in
            var pending = albums.enumerated().makeIterator()
            func enqueue() {
                guard let (index, album) = pending.next() else { return }
                group.addTask {
                    let songs = (try? await library.album(id: album.id).song) ?? []
                    return (index, songs.map { DisplayableSong(from: $0) })
                }
            }
            for _ in 0..<maxConcurrentRequests { enqueue() }
            for await (index, songs) in group {
                byIndex[index] = songs
                enqueue()
            }
        }
        return albums.indices.flatMap { byIndex[$0] ?? [] }
    }
}
