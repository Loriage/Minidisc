import Foundation
import OSLog
import SwiftData

actor OfflineLibraryReader {
    private struct FileEntry: Sendable {
        let songId: String
        let filePath: String
        let fileSize: Int64
    }

    private let modelContainer: ModelContainer
    private let downloadsDirectory: URL

    init(modelContainer: ModelContainer, downloadsDirectory: URL) {
        self.modelContainer = modelContainer
        self.downloadsDirectory = downloadsDirectory
    }

    func downloadedURL(forSongId songId: String, serverId: UUID) async -> URL? {
        let entry: FileEntry? = await MainActor.run {
            let context = ModelContext(modelContainer)
            let predicate = #Predicate<DownloadedTrack> { $0.songId == songId }
            let tracks = (try? context.fetch(FetchDescriptor(predicate: predicate))) ?? []
            return tracks.first(where: { $0.serverId == serverId }).map {
                FileEntry(songId: $0.songId, filePath: $0.filePath, fileSize: $0.fileSize)
            }
        }
        guard let entry else { return nil }
        return validURL(for: entry)
    }

    func downloadedSongIds(serverId: UUID) async -> Set<String> {
        let entries: [FileEntry] = await MainActor.run {
            let context = ModelContext(modelContainer)
            let tracks = (try? context.fetch(FetchDescriptor<DownloadedTrack>())) ?? []
            return tracks
                .filter { $0.serverId == serverId }
                .map {
                    FileEntry(songId: $0.songId, filePath: $0.filePath, fileSize: $0.fileSize)
                }
        }
        return Set(entries.compactMap {
            validURL(for: $0, logInvalid: false) == nil ? nil : $0.songId
        })
    }

    func localAlbumData(albumId: String, serverId: UUID) async -> LocalAlbumData? {
        await MainActor.run {
            let context = ModelContext(modelContainer)
            let allTracks = (try? context.fetch(FetchDescriptor<DownloadedTrack>())) ?? []
            let albumTracks = allTracks
                .filter { $0.albumId == albumId && $0.serverId == serverId }
                .sorted { ($0.trackNumber ?? Int.max) < ($1.trackNumber ?? Int.max) }
            guard let first = albumTracks.first else { return nil }

            let allAlbums = (try? context.fetch(FetchDescriptor<DownloadedAlbum>())) ?? []
            let albumRecord = allAlbums.first {
                $0.albumId == albumId && $0.serverId == serverId
            }
            return LocalAlbumData(
                albumId: albumId,
                albumName: albumRecord?.name ?? first.album ?? albumId,
                artistName: albumRecord?.artist ?? first.artist,
                coverArtId: albumRecord?.coverArtId ?? first.coverArtId,
                songs: albumTracks.map { DisplayableSong(from: $0) }
            )
        }
    }

    func localArtistData(
        artistId: String,
        artistName: String?,
        serverId: UUID
    ) async -> LocalArtistData? {
        await MainActor.run {
            let context = ModelContext(modelContainer)
            let allTracks = ((try? context.fetch(FetchDescriptor<DownloadedTrack>())) ?? [])
                .filter { $0.serverId == serverId }
            let artistTracks = allTracks.filter { track in
                if let id = track.artistId { return id == artistId }
                guard let artistName, let trackArtist = track.artist else { return false }
                return trackArtist.localizedCaseInsensitiveCompare(artistName) == .orderedSame
            }
            guard let firstArtistTrack = artistTracks.first else { return nil }

            let allAlbums = ((try? context.fetch(FetchDescriptor<DownloadedAlbum>())) ?? [])
                .filter { $0.serverId == serverId }
            let tracksByAlbum = Dictionary(
                grouping: artistTracks.compactMap { track in
                    track.albumId.map { ($0, track) }
                },
                by: { $0.0 }
            )
            let albums = tracksByAlbum
                .map { albumId, entries -> LocalAlbumData in
                    let tracks = entries.map { $0.1 }
                    let ordered = tracks.sorted {
                        ($0.trackNumber ?? Int.max) < ($1.trackNumber ?? Int.max)
                    }
                    let first = ordered[0]
                    let record = allAlbums.first { $0.albumId == albumId }
                    return LocalAlbumData(
                        albumId: albumId,
                        albumName: record?.name ?? first.album ?? albumId,
                        artistName: record?.artist ?? first.artist,
                        coverArtId: record?.coverArtId ?? first.coverArtId,
                        songs: ordered.map { DisplayableSong(from: $0) }
                    )
                }
                .sorted {
                    $0.albumName.localizedCaseInsensitiveCompare($1.albumName) == .orderedAscending
                }
            let standaloneSongs = artistTracks
                .filter { $0.albumId == nil }
                .sorted {
                    $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
                .map { DisplayableSong(from: $0) }

            return LocalArtistData(
                artistId: artistId,
                artistName: artistName ?? firstArtistTrack.artist ?? artistId,
                coverArtId: albums.first?.coverArtId ?? firstArtistTrack.coverArtId,
                albums: albums,
                tracks: albums.flatMap(\.songs) + standaloneSongs
            )
        }
    }

    func localPlaylistData(playlistId: String, serverId: UUID) async -> LocalPlaylistData? {
        await MainActor.run {
            let context = ModelContext(modelContainer)
            let allPlaylists = (try? context.fetch(FetchDescriptor<DownloadedPlaylist>())) ?? []
            guard let playlist = allPlaylists.first(where: {
                $0.playlistId == playlistId && $0.serverId == serverId
            }) else {
                return nil
            }

            let tracksBySongId = Dictionary(
                (((try? context.fetch(FetchDescriptor<DownloadedTrack>())) ?? [])
                    .filter { $0.serverId == serverId })
                    .map { ($0.songId, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let songs = playlist.songIds
                .compactMap { tracksBySongId[$0] }
                .map { DisplayableSong(from: $0) }
            return LocalPlaylistData(
                playlistId: playlist.playlistId,
                name: playlist.name,
                coverArtId: playlist.coverArtId,
                songs: songs
            )
        }
    }

    func backfillPlaylistSongIds(
        playlistId: String,
        serverId: UUID,
        orderedSongIds: [String]
    ) async {
        await MainActor.run {
            let context = ModelContext(modelContainer)
            let playlists = (try? context.fetch(FetchDescriptor<DownloadedPlaylist>())) ?? []
            guard let record = playlists.first(where: {
                $0.playlistId == playlistId && $0.serverId == serverId
            }), record.songIds.isEmpty else {
                return
            }

            let downloaded = Set(
                (((try? context.fetch(FetchDescriptor<DownloadedTrack>())) ?? [])
                    .filter { $0.serverId == serverId })
                    .map(\.songId)
            )
            let repaired = orderedSongIds.filter { downloaded.contains($0) }
            guard !repaired.isEmpty else { return }

            record.songIds = repaired
            do {
                try context.save()
                Logger.download.info(
                    "Back-filled \(repaired.count, privacy: .public) songId(s) for playlist '\(playlistId, privacy: .public)'"
                )
            } catch {
                Logger.download.error(
                    "Failed to back-fill playlist '\(playlistId, privacy: .public)': \(error, privacy: .public)"
                )
            }
        }
    }

    private func validURL(for entry: FileEntry, logInvalid: Bool = true) -> URL? {
        let url = downloadsDirectory.appendingPathComponent(entry.filePath)
        let diskSize = (
            try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64
        ) ?? 0
        guard diskSize > 0, entry.fileSize == 0 || diskSize == entry.fileSize else {
            if logInvalid {
                Logger.download.warning(
                    "Downloaded track record exists but file missing or invalid (disk \(diskSize) bytes, record \(entry.fileSize)): \(entry.filePath, privacy: .public)"
                )
            }
            return nil
        }
        return url
    }
}
