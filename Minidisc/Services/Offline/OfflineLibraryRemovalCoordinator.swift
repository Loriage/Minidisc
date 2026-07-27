// Minidisc — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import OSLog
import SwiftData

actor OfflineLibraryRemovalCoordinator {
    private let modelContainer: ModelContainer
    private let downloadsDirectory: URL

    init(modelContainer: ModelContainer, downloadsDirectory: URL) {
        self.modelContainer = modelContainer
        self.downloadsDirectory = downloadsDirectory
    }

    func remove(
        _ request: OfflineLibraryRemovalPlanner.Request,
        serverId: UUID
    ) async throws {
        let filePaths = try await MainActor.run {
            try Self.commitRemoval(
                request,
                serverId: serverId,
                modelContainer: modelContainer
            )
        }
        removeFiles(at: filePaths)
    }

    @MainActor
    private static func commitRemoval(
        _ request: OfflineLibraryRemovalPlanner.Request,
        serverId: UUID,
        modelContainer: ModelContainer
    ) throws -> Set<String> {
        let context = ModelContext(modelContainer)
        let allTracks = try context.fetch(FetchDescriptor<DownloadedTrack>())
        let allAlbums = try context.fetch(FetchDescriptor<DownloadedAlbum>())
        let allPlaylists = try context.fetch(FetchDescriptor<DownloadedPlaylist>())

        let serverTracks = allTracks.filter { $0.serverId == serverId }
        let serverAlbums = allAlbums.filter { $0.serverId == serverId }
        let serverPlaylists = allPlaylists.filter { $0.serverId == serverId }
        let snapshot = OfflineLibraryRemovalPlanner.Snapshot(
            tracks: serverTracks.map {
                OfflineLibraryRemovalPlanner.Track(
                    songId: $0.songId,
                    albumId: $0.albumId
                )
            },
            downloadedAlbumIds: Set(serverAlbums.map(\.albumId)),
            playlists: serverPlaylists.map {
                OfflineLibraryRemovalPlanner.Playlist(
                    playlistId: $0.playlistId,
                    songIds: Set($0.songIds)
                )
            }
        )
        let plan = OfflineLibraryRemovalPlanner.plan(for: request, snapshot: snapshot)
        let tracksToRemove = serverTracks.filter { plan.trackIdsToPurge.contains($0.songId) }
        let trackRecordIdsToRemove = Set(tracksToRemove.map(\.id))
        let affectedAlbumIds = Set(tracksToRemove.compactMap(\.albumId))
        let remainingTracks = serverTracks.filter { !trackRecordIdsToRemove.contains($0.id) }

        let albumRecordIdsToRemove: Set<UUID>
        let playlistRecordIdsToRemove: Set<UUID>
        switch request {
        case .track:
            albumRecordIdsToRemove = []
            playlistRecordIdsToRemove = []

        case .album(let albumId):
            albumRecordIdsToRemove = Set(
                serverAlbums.lazy
                    .filter { $0.albumId == albumId }
                    .map(\.id)
            )
            playlistRecordIdsToRemove = []

        case .playlist(let playlistId):
            albumRecordIdsToRemove = []
            playlistRecordIdsToRemove = Set(
                serverPlaylists.lazy
                    .filter { $0.playlistId == playlistId }
                    .map(\.id)
            )
        }

        serverAlbums
            .filter { albumRecordIdsToRemove.contains($0.id) }
            .forEach { context.delete($0) }
        serverPlaylists
            .filter { playlistRecordIdsToRemove.contains($0.id) }
            .forEach { context.delete($0) }
        tracksToRemove.forEach { context.delete($0) }

        for album in serverAlbums
        where !albumRecordIdsToRemove.contains(album.id)
            && affectedAlbumIds.contains(album.albumId) {
            album.tracksCount = remainingTracks.filter { $0.albumId == album.albumId }.count
        }

        for playlist in serverPlaylists
        where !playlistRecordIdsToRemove.contains(playlist.id) {
            let remainingSongIds = playlist.songIds.filter {
                !plan.trackIdsToPurge.contains($0)
            }
            guard remainingSongIds != playlist.songIds else { continue }
            playlist.songIds = remainingSongIds
            playlist.tracksCount = remainingSongIds.count
        }

        try context.save()
        return Set(tracksToRemove.map(\.filePath))
    }

    private func removeFiles(at relativePaths: Set<String>) {
        let fileManager = FileManager.default
        for relativePath in relativePaths.sorted() {
            let fileURL = downloadsDirectory.appendingPathComponent(relativePath)
            guard fileManager.fileExists(atPath: fileURL.path) else { continue }
            do {
                try fileManager.removeItem(at: fileURL)
            } catch {
                Logger.download.error(
                    "Offline metadata removed but audio file cleanup failed for '\(relativePath, privacy: .public)': \(error, privacy: .public)"
                )
            }
        }
    }
}
