// Minidisc — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Testing
@testable import Minidisc

@Suite("Offline library removal planner")
struct OfflineLibraryRemovalPlannerTests {
    private func track(_ songId: String, albumId: String? = nil) -> OfflineLibraryRemovalPlanner.Track {
        .init(songId: songId, albumId: albumId)
    }

    private func playlist(
        _ playlistId: String,
        songIds: Set<String>
    ) -> OfflineLibraryRemovalPlanner.Playlist {
        .init(playlistId: playlistId, songIds: songIds)
    }

    private func snapshot(
        tracks: [OfflineLibraryRemovalPlanner.Track] = [],
        downloadedAlbumIds: Set<String> = [],
        playlists: [OfflineLibraryRemovalPlanner.Playlist] = []
    ) -> OfflineLibraryRemovalPlanner.Snapshot {
        .init(
            tracks: tracks,
            downloadedAlbumIds: downloadedAlbumIds,
            playlists: playlists
        )
    }

    @Test("removing one track always purges it explicitly")
    func explicitTrackRemovalPurgesTrack() {
        let plan = OfflineLibraryRemovalPlanner.plan(
            for: .track(songId: "shared"),
            snapshot: snapshot(
                tracks: [track("shared", albumId: "album")],
                downloadedAlbumIds: ["album"],
                playlists: [playlist("playlist", songIds: ["shared"])]
            )
        )

        #expect(plan.trackIdsToPurge == ["shared"])
    }

    @Test("removing an album preserves tracks owned by a playlist")
    func albumRemovalPreservesPlaylistTracks() {
        let plan = OfflineLibraryRemovalPlanner.plan(
            for: .album(albumId: "album"),
            snapshot: snapshot(
                tracks: [
                    track("shared", albumId: "album"),
                    track("album-only", albumId: "album"),
                    track("other", albumId: "other-album")
                ],
                playlists: [playlist("playlist", songIds: ["shared"])]
            )
        )

        #expect(plan.trackIdsToPurge == ["album-only"])
    }

    @Test("removing an album preserves tracks referenced by any playlist")
    func albumRemovalPreservesTracksAcrossPlaylists() {
        let plan = OfflineLibraryRemovalPlanner.plan(
            for: .album(albumId: "album"),
            snapshot: snapshot(
                tracks: [
                    track("first", albumId: "album"),
                    track("second", albumId: "album")
                ],
                playlists: [
                    playlist("one", songIds: ["first"]),
                    playlist("two", songIds: ["second"])
                ]
            )
        )

        #expect(plan.trackIdsToPurge.isEmpty)
    }

    @Test("removing a playlist preserves tracks owned by another playlist")
    func playlistRemovalPreservesOtherPlaylistTracks() {
        let plan = OfflineLibraryRemovalPlanner.plan(
            for: .playlist(playlistId: "target"),
            snapshot: snapshot(
                playlists: [
                    playlist("target", songIds: ["shared", "target-only"]),
                    playlist("other", songIds: ["shared"])
                ]
            )
        )

        #expect(plan.trackIdsToPurge == ["target-only"])
    }

    @Test("removing a playlist preserves tracks owned by a downloaded album")
    func playlistRemovalPreservesDownloadedAlbumTracks() {
        let plan = OfflineLibraryRemovalPlanner.plan(
            for: .playlist(playlistId: "target"),
            snapshot: snapshot(
                tracks: [
                    track("shared", albumId: "album"),
                    track("playlist-only")
                ],
                downloadedAlbumIds: ["album"],
                playlists: [
                    playlist("target", songIds: ["shared", "playlist-only"])
                ]
            )
        )

        #expect(plan.trackIdsToPurge == ["playlist-only"])
    }

    @Test("album metadata alone does not retain a playlist track")
    func playlistRemovalRequiresDownloadedAlbumIntent() {
        let plan = OfflineLibraryRemovalPlanner.plan(
            for: .playlist(playlistId: "target"),
            snapshot: snapshot(
                tracks: [track("song", albumId: "album")],
                playlists: [playlist("target", songIds: ["song"])]
            )
        )

        #expect(plan.trackIdsToPurge == ["song"])
    }

    @Test("removing a missing collection is idempotent")
    func missingCollectionPurgesNothing() {
        let library = snapshot(
            tracks: [track("song", albumId: "album")],
            downloadedAlbumIds: ["album"],
            playlists: [playlist("playlist", songIds: ["song"])]
        )

        #expect(OfflineLibraryRemovalPlanner.plan(
            for: .album(albumId: "missing"),
            snapshot: library
        ).trackIdsToPurge.isEmpty)
        #expect(OfflineLibraryRemovalPlanner.plan(
            for: .playlist(playlistId: "missing"),
            snapshot: library
        ).trackIdsToPurge.isEmpty)
    }
}
