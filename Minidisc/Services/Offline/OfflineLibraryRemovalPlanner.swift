// Minidisc — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

/// Pure ownership policy for removing offline tracks and collections.
nonisolated enum OfflineLibraryRemovalPlanner {
    enum Request: Equatable, Sendable {
        case track(songId: String)
        case album(albumId: String)
        case playlist(playlistId: String)
    }

    struct Track: Equatable, Sendable {
        let songId: String
        let albumId: String?
    }

    struct Playlist: Equatable, Sendable {
        let playlistId: String
        let songIds: Set<String>
    }

    struct Snapshot: Equatable, Sendable {
        let tracks: [Track]
        let downloadedAlbumIds: Set<String>
        let playlists: [Playlist]

        static let empty = Snapshot(tracks: [], downloadedAlbumIds: [], playlists: [])
    }

    struct Plan: Equatable, Sendable {
        let trackIdsToPurge: Set<String>
    }

    static func plan(for request: Request, snapshot: Snapshot) -> Plan {
        switch request {
        case .track(let songId):
            return Plan(trackIdsToPurge: [songId])

        case .album(let albumId):
            let ownedTrackIds = Set(
                snapshot.tracks.lazy
                    .filter { $0.albumId == albumId }
                    .map(\.songId)
            )
            let playlistOwnedTrackIds = Set(snapshot.playlists.flatMap(\.songIds))
            return Plan(trackIdsToPurge: ownedTrackIds.subtracting(playlistOwnedTrackIds))

        case .playlist(let playlistId):
            let ownedTrackIds = Set(
                snapshot.playlists.lazy
                    .filter { $0.playlistId == playlistId }
                    .flatMap(\.songIds)
            )
            let otherPlaylistTrackIds = Set(
                snapshot.playlists.lazy
                    .filter { $0.playlistId != playlistId }
                    .flatMap(\.songIds)
            )
            let downloadedAlbumTrackIds: Set<String> = Set(
                snapshot.tracks.lazy.compactMap { track -> String? in
                    guard
                        ownedTrackIds.contains(track.songId),
                        let albumId = track.albumId,
                        snapshot.downloadedAlbumIds.contains(albumId)
                    else {
                        return nil
                    }
                    return track.songId
                }
            )
            let retainedTrackIds = otherPlaylistTrackIds.union(downloadedAlbumTrackIds)
            return Plan(trackIdsToPurge: ownedTrackIds.subtracting(retainedTrackIds))
        }
    }
}
