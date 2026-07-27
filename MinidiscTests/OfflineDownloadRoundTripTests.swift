// Minidisc — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Testing
import Foundation
import SwiftData
import SwiftSonic
@testable import Minidisc

/// Exercises the REAL `DownloadService.localPlaylistData` reconstruction against a real
/// in-memory SwiftData store — not a hand-built `LocalPlaylistData` stub. This is the layer
/// the throw-only ViewModel tests never touched, where the offline-playlist bug actually lived.
@Suite("Offline downloads — real localPlaylistData round-trip")
@MainActor
struct OfflineDownloadRoundTripTests {

    private func makeService() throws -> (service: DownloadService, container: ModelContainer, serverId: UUID) {
        let container = try ModelContainer.minidisc(inMemory: true)
        let service = DownloadService(
            serverService: MockServerService(),
            modelContainer: container,
            toastService: ToastService()
        )
        return (service, container, UUID())
    }

    private func insertTrack(
        _ container: ModelContainer,
        songId: String,
        serverId: UUID,
        track: Int,
        albumId: String? = "album-1"
    ) {
        container.mainContext.insert(
            DownloadedTrack(
                songId: songId,
                serverId: serverId,
                albumId: albumId,
                filePath: "\(serverId.uuidString)/\(songId).mp3",
                fileSize: 1234,
                mimeType: "audio/mpeg",
                title: "Track \(songId)",
                artist: "Artist",
                album: "Album",
                trackNumber: track
            )
        )
    }

    @Test("real localPlaylistData reconstructs tracks in stored playlist order")
    func reconstructsInOrder() async throws {
        let (service, container, sid) = try makeService()
        // Insert out of order on purpose; songIds defines the order, not insertion/track number.
        insertTrack(container, songId: "s2", serverId: sid, track: 2)
        insertTrack(container, songId: "s1", serverId: sid, track: 1)
        container.mainContext.insert(
            DownloadedPlaylist(
                playlistId: "pl-1", serverId: sid, name: "Road Trip",
                tracksCount: 2, totalTracksCount: 2, songIds: ["s1", "s2"]
            )
        )
        try container.mainContext.save()

        let data = await service.localPlaylistData(playlistId: "pl-1", serverId: sid)
        #expect(data?.songs.map(\.id) == ["s1", "s2"])
        #expect(data?.name == "Road Trip")
    }

    @Test("localPlaylistData returns nil when there is no downloaded playlist record")
    func nilWhenNoRecord() async throws {
        let (service, _, sid) = try makeService()
        let data = await service.localPlaylistData(playlistId: "missing", serverId: sid)
        #expect(data == nil)
    }

    @Test("localPlaylistData ignores tracks from a different server")
    func ignoresOtherServerTracks() async throws {
        let (service, container, sid) = try makeService()
        let otherServer = UUID()
        insertTrack(container, songId: "s1", serverId: sid, track: 1)
        insertTrack(container, songId: "s2", serverId: otherServer, track: 2) // wrong server
        container.mainContext.insert(
            DownloadedPlaylist(
                playlistId: "pl-1", serverId: sid, name: "Road Trip",
                tracksCount: 2, totalTracksCount: 2, songIds: ["s1", "s2"]
            )
        )
        try container.mainContext.save()

        let data = await service.localPlaylistData(playlistId: "pl-1", serverId: sid)
        #expect(data?.songs.map(\.id) == ["s1"]) // s2 belongs to another server, dropped
    }

    @Test("backfillPlaylistSongIds repairs an empty songIds from on-disk tracks, in order")
    func backfillRepairsEmptySongIds() async throws {
        let (service, container, sid) = try makeService()
        insertTrack(container, songId: "s1", serverId: sid, track: 1)
        insertTrack(container, songId: "s2", serverId: sid, track: 2)
        container.mainContext.insert(
            DownloadedPlaylist(
                playlistId: "pl-1", serverId: sid, name: "Road Trip",
                tracksCount: 2, totalTracksCount: 2, songIds: [] // pre-migration record
            )
        )
        try container.mainContext.save()

        // Empty songIds → nothing reconstructs yet.
        let before = await service.localPlaylistData(playlistId: "pl-1", serverId: sid)
        #expect(before?.songs.isEmpty == true)

        // Repair from authoritative order; "s3" isn't downloaded and must be dropped.
        await service.backfillPlaylistSongIds(
            playlistId: "pl-1", serverId: sid, orderedSongIds: ["s2", "s1", "s3"]
        )

        let after = await service.localPlaylistData(playlistId: "pl-1", serverId: sid)
        #expect(after?.songs.map(\.id) == ["s2", "s1"])
    }

    @Test("backfillPlaylistSongIds does not overwrite an already-populated songIds")
    func backfillLeavesPopulatedAlone() async throws {
        let (service, container, sid) = try makeService()
        insertTrack(container, songId: "s1", serverId: sid, track: 1)
        insertTrack(container, songId: "s2", serverId: sid, track: 2)
        container.mainContext.insert(
            DownloadedPlaylist(
                playlistId: "pl-1", serverId: sid, name: "Road Trip",
                tracksCount: 2, totalTracksCount: 2, songIds: ["s1", "s2"]
            )
        )
        try container.mainContext.save()

        await service.backfillPlaylistSongIds(
            playlistId: "pl-1", serverId: sid, orderedSongIds: ["s2", "s1"]
        )

        let data = await service.localPlaylistData(playlistId: "pl-1", serverId: sid)
        #expect(data?.songs.map(\.id) == ["s1", "s2"]) // unchanged
    }

    @Test("downloadedSongIds excludes records whose file is missing")
    func downloadedIdsExcludeMissingFiles() async throws {
        let (service, container, sid) = try makeService()
        insertTrack(container, songId: "missing-on-disk", serverId: sid, track: 1)
        try container.mainContext.save()

        let ids = await service.downloadedSongIds(serverId: sid)

        #expect(ids.isEmpty)
    }

    @Test("removing an album keeps tracks referenced by a downloaded playlist")
    func removingAlbumPreservesPlaylistTracks() async throws {
        let (service, container, sid) = try makeService()
        insertTrack(container, songId: "shared", serverId: sid, track: 1)
        insertTrack(container, songId: "album-only", serverId: sid, track: 2)
        container.mainContext.insert(
            DownloadedAlbum(
                albumId: "album-1",
                serverId: sid,
                name: "Album",
                tracksCount: 2,
                totalTracksCount: 2
            )
        )
        container.mainContext.insert(
            DownloadedPlaylist(
                playlistId: "pl-1",
                serverId: sid,
                name: "Playlist",
                tracksCount: 1,
                totalTracksCount: 1,
                songIds: ["shared"]
            )
        )
        try container.mainContext.save()

        try await service.remove(albumId: "album-1", serverId: sid)

        let playlist = await service.localPlaylistData(playlistId: "pl-1", serverId: sid)
        #expect(playlist?.songs.map(\.id) == ["shared"])
        let context = ModelContext(container)
        let remainingIds = Set(try context.fetch(FetchDescriptor<DownloadedTrack>()).map(\.songId))
        #expect(remainingIds == ["shared"])
        #expect(try context.fetch(FetchDescriptor<DownloadedAlbum>()).isEmpty)
    }

    @Test("removing an album ignores playlist ownership from another server")
    func removingAlbumIgnoresOtherServerPlaylist() async throws {
        let (service, container, sid) = try makeService()
        let otherServerId = UUID()
        insertTrack(container, songId: "shared-id", serverId: sid, track: 1)
        container.mainContext.insert(
            DownloadedAlbum(
                albumId: "album-1",
                serverId: sid,
                name: "Album",
                tracksCount: 1,
                totalTracksCount: 1
            )
        )
        container.mainContext.insert(
            DownloadedPlaylist(
                playlistId: "other-server-playlist",
                serverId: otherServerId,
                name: "Other server",
                tracksCount: 1,
                totalTracksCount: 1,
                songIds: ["shared-id"]
            )
        )
        try container.mainContext.save()

        try await service.remove(albumId: "album-1", serverId: sid)

        let context = ModelContext(container)
        let remainingTracks = try context.fetch(FetchDescriptor<DownloadedTrack>())
        #expect(remainingTracks.allSatisfy { $0.serverId != sid })
        let remainingPlaylists = try context.fetch(FetchDescriptor<DownloadedPlaylist>())
        #expect(remainingPlaylists.contains { $0.serverId == otherServerId })
    }

    @Test("removing a playlist keeps album tracks and purges playlist-only tracks")
    func removingPlaylistPreservesAlbumTracks() async throws {
        let (service, container, sid) = try makeService()
        insertTrack(container, songId: "shared", serverId: sid, track: 1)
        insertTrack(container, songId: "playlist-only", serverId: sid, track: 2, albumId: nil)
        container.mainContext.insert(
            DownloadedAlbum(
                albumId: "album-1",
                serverId: sid,
                name: "Album",
                tracksCount: 1,
                totalTracksCount: 1
            )
        )
        container.mainContext.insert(
            DownloadedPlaylist(
                playlistId: "pl-1",
                serverId: sid,
                name: "Playlist",
                tracksCount: 2,
                totalTracksCount: 2,
                songIds: ["shared", "playlist-only"]
            )
        )
        try container.mainContext.save()

        try await service.remove(playlistId: "pl-1", serverId: sid)

        let album = await service.localAlbumData(albumId: "album-1", serverId: sid)
        #expect(album?.songs.map(\.id) == ["shared"])
        let context = ModelContext(container)
        let remainingIds = Set(try context.fetch(FetchDescriptor<DownloadedTrack>()).map(\.songId))
        #expect(remainingIds == ["shared"])
        #expect(try context.fetch(FetchDescriptor<DownloadedPlaylist>()).isEmpty)
    }

    @Test("removing a playlist ignores album ownership from another server")
    func removingPlaylistIgnoresOtherServerAlbum() async throws {
        let (service, container, sid) = try makeService()
        let otherServerId = UUID()
        insertTrack(container, songId: "shared-id", serverId: sid, track: 1)
        container.mainContext.insert(
            DownloadedAlbum(
                albumId: "album-1",
                serverId: otherServerId,
                name: "Other server album",
                tracksCount: 1,
                totalTracksCount: 1
            )
        )
        container.mainContext.insert(
            DownloadedPlaylist(
                playlistId: "playlist-1",
                serverId: sid,
                name: "Playlist",
                tracksCount: 1,
                totalTracksCount: 1,
                songIds: ["shared-id"]
            )
        )
        try container.mainContext.save()

        try await service.remove(playlistId: "playlist-1", serverId: sid)

        let context = ModelContext(container)
        let remainingTracks = try context.fetch(FetchDescriptor<DownloadedTrack>())
        #expect(remainingTracks.allSatisfy { $0.serverId != sid })
        let remainingAlbums = try context.fetch(FetchDescriptor<DownloadedAlbum>())
        #expect(remainingAlbums.contains { $0.serverId == otherServerId })
    }

    @Test("removing one track refreshes album and playlist completeness counts")
    func removingTrackRefreshesCounts() async throws {
        let (service, container, sid) = try makeService()
        insertTrack(container, songId: "s1", serverId: sid, track: 1)
        insertTrack(container, songId: "s2", serverId: sid, track: 2)
        container.mainContext.insert(
            DownloadedAlbum(
                albumId: "album-1",
                serverId: sid,
                name: "Album",
                tracksCount: 2,
                totalTracksCount: 2
            )
        )
        container.mainContext.insert(
            DownloadedPlaylist(
                playlistId: "pl-1",
                serverId: sid,
                name: "Playlist",
                tracksCount: 2,
                totalTracksCount: 2,
                songIds: ["s1", "s2"]
            )
        )
        try container.mainContext.save()

        try await service.remove(songId: "s1", serverId: sid)

        let context = ModelContext(container)
        let album = try #require(context.fetch(FetchDescriptor<DownloadedAlbum>()).first)
        let playlist = try #require(context.fetch(FetchDescriptor<DownloadedPlaylist>()).first)
        #expect(album.tracksCount == 1)
        #expect(!album.isComplete)
        #expect(playlist.songIds == ["s2"])
        #expect(playlist.tracksCount == 1)
        #expect(!playlist.isComplete)
    }

    @Test("removing a partial album from Settings preserves playlist-owned tracks")
    @MainActor
    func removingPartialAlbumFromSettingsPreservesPlaylistTracks() async throws {
        let (service, container, sid) = try makeService()
        insertTrack(container, songId: "shared", serverId: sid, track: 1)
        insertTrack(container, songId: "partial-only", serverId: sid, track: 2)
        container.mainContext.insert(
            DownloadedPlaylist(
                playlistId: "pl-1",
                serverId: sid,
                name: "Playlist",
                tracksCount: 1,
                totalTracksCount: 1,
                songIds: ["shared"]
            )
        )
        try container.mainContext.save()
        let display = DownloadedAlbumDisplay(
            id: "album-1",
            albumId: "album-1",
            serverId: sid,
            name: "Partial album",
            artist: "Artist",
            coverArtId: nil,
            downloadedTracksCount: 2,
            totalTracksCount: nil,
            hasFullDownloadIntent: false
        )
        let viewModel = DownloadsViewModel(
            modelContainer: container,
            downloadService: service,
            serverState: ServerState()
        )

        await viewModel.removeAlbum(display)

        let context = ModelContext(container)
        let remainingIds = Set(try context.fetch(FetchDescriptor<DownloadedTrack>()).map(\.songId))
        #expect(remainingIds == ["shared"])
        #expect(viewModel.trackCount == 1)
    }

    @Test("clear all removes album, playlist, and standalone download records")
    @MainActor
    func clearAllRemovesEveryDownloadRecord() async throws {
        let (service, container, sid) = try makeService()
        insertTrack(container, songId: "album-and-playlist", serverId: sid, track: 1)
        insertTrack(container, songId: "standalone", serverId: sid, track: 2, albumId: nil)
        container.mainContext.insert(
            DownloadedAlbum(
                albumId: "album-1",
                serverId: sid,
                name: "Album",
                tracksCount: 1,
                totalTracksCount: 1
            )
        )
        container.mainContext.insert(
            DownloadedPlaylist(
                playlistId: "pl-1",
                serverId: sid,
                name: "Playlist",
                tracksCount: 1,
                totalTracksCount: 1,
                songIds: ["album-and-playlist"]
            )
        )
        try container.mainContext.save()
        let viewModel = DownloadsViewModel(
            modelContainer: container,
            downloadService: service,
            serverState: ServerState()
        )

        await viewModel.clearAll()

        let context = ModelContext(container)
        #expect(try context.fetch(FetchDescriptor<DownloadedAlbum>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<DownloadedPlaylist>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<DownloadedTrack>()).isEmpty)
        #expect(viewModel.displayAlbums.isEmpty)
        #expect(viewModel.downloadedPlaylists.isEmpty)
        #expect(viewModel.trackCount == 0)
        #expect(!viewModel.isClearingAll)
    }
}
