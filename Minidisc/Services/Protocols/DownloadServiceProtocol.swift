import Foundation
import SwiftSonic

nonisolated enum DownloadTransferStatus: String, Sendable, Codable {
    case queued, downloading, waiting, processing, failed
}

nonisolated struct DownloadProgress: Sendable {
    let songId: String
    let serverId: UUID
    let progress: Double    // 0.0 → 1.0
    let totalBytes: Int64?
    let receivedBytes: Int64
    var title: String? = nil
    var status: DownloadTransferStatus = .downloading
    var error: UserFacingError? = nil
}

nonisolated struct LocalAlbumData: Sendable {
    let albumId: String
    let albumName: String
    let artistName: String?
    let coverArtId: String?
    let songs: [DisplayableSong]
}

/// An artist reconstructed from what is on disk. `albums` carries each downloaded album with its tracks;
/// `tracks` is the same set flattened, in album/track order, for playback.
nonisolated struct LocalArtistData: Sendable {
    let artistId: String
    let artistName: String
    let coverArtId: String?
    let albums: [LocalAlbumData]
    let tracks: [DisplayableSong]
}

nonisolated struct LocalPlaylistData: Sendable {
    let playlistId: String
    let name: String
    let coverArtId: String?
    let songs: [DisplayableSong]
}

protocol DownloadServiceProtocol: AnyObject, Sendable {
    /// Live stream of in-progress downloads for UI progress display.
    var progressStream: AsyncStream<[DownloadProgress]> { get }

    func downloadedURL(forSongId songId: String, serverId: UUID) async -> URL?
    func isDownloaded(songId: String, serverId: UUID) async -> Bool
    /// Returns all song IDs that have been fully downloaded for a given server.
    func downloadedSongIds(serverId: UUID) async -> Set<String>

    /// Returns the local file URL for a downloaded cover art, or nil if not cached.
    func localCoverArtURL(forId coverArtId: String) async -> URL?

    /// Persists cover image data to the shared cover art directory (best-effort, errors are logged).
    func persistCover(_ data: Data, forId coverArtId: String) async

    /// Removes the cached cover art file for the given ID. No-op if not on disk.
    func removeCover(forId coverArtId: String) async

    /// Deletes orphaned cover files whose name is not in `referencedIds`. Returns count deleted.
    @discardableResult
    func garbageCollectOrphanedCovers(referencedIds: Set<String>) async -> Int

    /// Number of files and total bytes in the persisted-cover store.
    func coverCacheStats() async -> (count: Int, bytes: Int64)

    /// Deletes every persisted cover. Downloaded audio is untouched; covers re-download on demand.
    func clearAllCovers() async

    /// Returns offline-playable album data assembled from persisted tracks, or nil if not downloaded.
    func localAlbumData(albumId: String, serverId: UUID) async -> LocalAlbumData?
    /// Returns offline-playable playlist data assembled from persisted tracks, or nil if not downloaded.
    func localPlaylistData(playlistId: String, serverId: UUID) async -> LocalPlaylistData?
    /// Returns the artist's downloaded albums and tracks, or nil if nothing of theirs is on disk.
    /// `artistName` is a fallback matcher for tracks whose server omitted `artistId`.
    func localArtistData(artistId: String, artistName: String?, serverId: UUID) async -> LocalArtistData?

    /// Repairs a downloaded playlist whose `songIds` is empty (e.g. records written before the
    /// field existed) by persisting the authoritative track order intersected with the tracks
    /// actually on disk. No-op when `songIds` is already populated or the record is absent.
    /// Lets pre-migration downloads become readable offline after one online open.
    func backfillPlaylistSongIds(playlistId: String, serverId: UUID, orderedSongIds: [String]) async

    /// Requests are persisted before system-owned transfers start.
    func download(song: Song, serverId: UUID) async throws
    func download(album: AlbumID3, serverId: UUID) async throws
    func download(playlist: PlaylistWithSongs, serverId: UUID) async throws

    /// Returns `true` if a download task is currently in-flight for this song.
    func isDownloading(songId: String, serverId: UUID) async -> Bool
    func isDownloadingAlbum(_ albumId: String) async -> Bool
    func isDownloadingPlaylist(_ playlistId: String) async -> Bool
    func cancelDownload(songId: String, serverId: UUID) async throws
    /// Commits offline metadata first; audio-file cleanup then runs best-effort.
    func remove(songId: String, serverId: UUID) async throws
    func remove(albumId: String, serverId: UUID) async throws
    func remove(playlistId: String, serverId: UUID) async throws
    func removeAll() async throws
    func restorePendingDownloads() async
    func retryDownload(songId: String, serverId: UUID) async throws
}

extension DownloadServiceProtocol {
    func restorePendingDownloads() async {}
    func retryDownload(songId: String, serverId: UUID) async throws {}
}
