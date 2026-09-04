import Foundation

nonisolated struct PlaylistEdits: Sendable {
    let name: String?
    let orderedSongIDs: [String]?
    /// Always provide the intended description when replacing tracks, including an empty one.
    let description: String?
}

nonisolated enum PlaylistEditCommitter {
    static func commit(_ edits: PlaylistEdits, playlistID: String, service: any PlaylistServiceProtocol) async throws {
        // A replacement can reset metadata. Apply metadata after replacement, and stop on
        // the first failure. Retrying the same snapshot is idempotent even after partial success.
        if let ids = edits.orderedSongIDs {
            try Task.checkCancellation()
            try await service.reorderTracks(playlistId: playlistID, orderedSongIds: ids)
        }
        if let name = edits.name {
            try Task.checkCancellation()
            try await service.renamePlaylist(id: playlistID, newName: name)
        }
        if let description = edits.description {
            try Task.checkCancellation()
            try await service.updateDescription(id: playlistID, description: description)
        }
    }
}
