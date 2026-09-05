import Foundation
import SwiftSonic

nonisolated struct HomeFeedSnapshot: Codable, Sendable {
    var playlists: [IndexedPlaylistPayload] = []
    var recentlyPlayed: [AlbumID3] = []
    var recentlyAdded: [AlbumID3] = []
    var genres: [HomeFeedViewModel.GenreShelf] = []
    // Optional fields preserve compatibility with the previous on-disk feed.
    var favorites: HomeFavorites?
    var mostPlayed: [AlbumID3]?
}

/// Small, server-scoped presentation cache. Contains metadata only and is safe to discard.
actor HomeFeedCache {
    static let shared = HomeFeedCache()
    private let directory: URL

    init(directory: URL = URL.cachesDirectory.appendingPathComponent("minidisc-home", isDirectory: true)) {
        self.directory = directory
    }

    func load(serverID: UUID) -> HomeFeedSnapshot? {
        guard let data = try? Data(contentsOf: file(serverID)), data.count < 4_000_000 else { return nil }
        return try? JSONDecoder().decode(HomeFeedSnapshot.self, from: data)
    }

    func save(_ snapshot: HomeFeedSnapshot, serverID: UUID) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: file(serverID), options: .atomic)
    }

    private func file(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }
}
