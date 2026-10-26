import Foundation
import SwiftData

nonisolated struct DownloadedAlbumDisplay: Identifiable, Sendable, Hashable {
    let id: String
    let albumId: String
    let serverId: UUID
    let name: String
    let artist: String?
    let coverArtId: String?
    let downloadedTracksCount: Int
    /// Total tracks expected. `nil` for partial albums (no `DownloadedAlbum` record).
    let totalTracksCount: Int?
    /// `true` if a `DownloadedAlbum` record exists (the user explicitly downloaded the full album).
    let hasFullDownloadIntent: Bool
}

enum DownloadedAlbumMerger {
    /// Build a unified, deduplicated list of displayable albums from records + tracks.
    /// `records` provides full-intent albums with their `totalTracksCount`.
    /// `tracks` provides partial albums for any `albumId` not already in `records`.
    /// Returns sorted by album name (case-insensitive).
    static func merge(
        records: [DownloadedAlbum],
        tracks: [DownloadedTrack]
    ) -> [DownloadedAlbumDisplay] {
        var byAlbumId: [String: DownloadedAlbumDisplay] = [:]

        for record in records {
            let trackCount = tracks.filter {
                $0.albumId == record.albumId && $0.serverId == record.serverId
            }.count
            byAlbumId[record.albumId] = DownloadedAlbumDisplay(
                id: record.albumId,
                albumId: record.albumId,
                serverId: record.serverId,
                name: record.name,
                artist: record.artist,
                coverArtId: record.coverArtId,
                downloadedTracksCount: trackCount,
                totalTracksCount: record.totalTracksCount,
                hasFullDownloadIntent: true
            )
        }

        let groupedTracks: [String: [DownloadedTrack]] = tracks.reduce(into: [:]) { dict, track in
            guard let id = track.albumId else { return }
            dict[id, default: []].append(track)
        }
        for (albumId, group) in groupedTracks where byAlbumId[albumId] == nil {
            guard let first = group.first else { continue }
            byAlbumId[albumId] = DownloadedAlbumDisplay(
                id: albumId,
                albumId: albumId,
                serverId: first.serverId,
                name: first.album ?? "Unknown Album",
                artist: first.artist,
                coverArtId: first.coverArtId,
                downloadedTracksCount: group.count,
                totalTracksCount: nil,
                hasFullDownloadIntent: false
            )
        }

        return byAlbumId.values.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}
