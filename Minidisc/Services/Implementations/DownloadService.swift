// Minidisc — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftData
import SwiftSonic
import OSLog

// TODO(v1.x): switch to background URLSession with resume-after-kill support.
// v1 uses foreground URLSession — the user must keep the app open during download.
actor DownloadService: DownloadServiceProtocol {
    private let serverService: any ServerServiceProtocol
    private let modelContainer: ModelContainer
    private let downloadsDirectory: URL
    private let coverArtsDirectory: URL
    private let offlineLibraryReader: OfflineLibraryReader
    private let offlineRemovalCoordinator: OfflineLibraryRemovalCoordinator
    private var progressContinuation: AsyncStream<[DownloadProgress]>.Continuation?
    /// Keyed by "songId::serverId" to allow per-track cancellation.
    private var inFlightTasks: [String: Task<Void, Error>] = [:]
    private var activeAlbumDownloads: Set<String> = []
    private var activePlaylistDownloads: Set<String> = []
    private var isRemovingAllDownloads = false
    private let toastService: ToastService
    private let downloadSession: URLSession

    nonisolated let progressStream: AsyncStream<[DownloadProgress]>

    init(serverService: any ServerServiceProtocol, modelContainer: ModelContainer, toastService: ToastService) {
        self.serverService = serverService
        self.modelContainer = modelContainer
        self.toastService = toastService

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 30
        // A lossless track can legitimately take several minutes on a slow connection.
        // The old 30-second resource cap made those downloads fail deterministically even
        // while bytes were still arriving. Keep the short request/inactivity timeout, but
        // give the complete transfer a realistic upper bound.
        sessionConfig.timeoutIntervalForResource = 60 * 60
        self.downloadSession = URLSession(configuration: sessionConfig)

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let base = docs.appendingPathComponent("app.minidisc", isDirectory: true)
        let downloadsDirectory = base.appendingPathComponent("downloads", isDirectory: true)
        self.downloadsDirectory = downloadsDirectory
        self.coverArtsDirectory = base.appendingPathComponent("coverarts", isDirectory: true)
        self.offlineLibraryReader = OfflineLibraryReader(
            modelContainer: modelContainer,
            downloadsDirectory: downloadsDirectory
        )
        self.offlineRemovalCoordinator = OfflineLibraryRemovalCoordinator(
            modelContainer: modelContainer,
            downloadsDirectory: downloadsDirectory
        )

        // AsyncStream.init closure is called synchronously — cont is guaranteed set before init returns.
        var cont: AsyncStream<[DownloadProgress]>.Continuation!
        progressStream = AsyncStream<[DownloadProgress]> { cont = $0 }
        progressContinuation = cont
    }

    // MARK: - Lookup

    func downloadedURL(forSongId songId: String, serverId: UUID) async -> URL? {
        await offlineLibraryReader.downloadedURL(forSongId: songId, serverId: serverId)
    }

    func isDownloaded(songId: String, serverId: UUID) async -> Bool {
        await downloadedURL(forSongId: songId, serverId: serverId) != nil
    }

    func downloadedSongIds(serverId: UUID) async -> Set<String> {
        await offlineLibraryReader.downloadedSongIds(serverId: serverId)
    }

    func localCoverArtURL(forId coverArtId: String) async -> URL? {
        let url = coverArtsDirectory.appendingPathComponent(coverArtId)
        let exists = FileManager.default.fileExists(atPath: url.path)
        Logger.download.debug("localCoverArtURL id='\(coverArtId, privacy: .public)' path='\(url.path, privacy: .public)' exists=\(exists)")
        return exists ? url : nil
    }

    func persistCover(_ data: Data, forId coverArtId: String) async {
        let url = coverArtsDirectory.appendingPathComponent(coverArtId)
        Logger.download.debug("persistCover id='\(coverArtId, privacy: .public)' path='\(url.path, privacy: .public)' bytes=\(data.count, privacy: .public)")
        do {
            try FileManager.default.createDirectory(at: coverArtsDirectory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            Logger.download.debug("Failed to persist cover '\(coverArtId, privacy: .public)': \(error, privacy: .public)")
        }
    }

    func removeCover(forId coverArtId: String) async {
        let url = coverArtsDirectory.appendingPathComponent(coverArtId)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            Logger.download.debug("Failed to remove cover '\(coverArtId, privacy: .public)': \(error, privacy: .public)")
        }
    }

    @discardableResult
    func coverCacheStats() -> (count: Int, bytes: Int64) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: coverArtsDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return (0, 0) }
        var bytes: Int64 = 0
        for file in files {
            bytes += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return (files.count, bytes)
    }

    func clearAllCovers() {
        try? FileManager.default.removeItem(at: coverArtsDirectory)
    }

    func garbageCollectOrphanedCovers(referencedIds: Set<String>) async -> Int {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: coverArtsDirectory, includingPropertiesForKeys: nil) else {
            return 0
        }
        var deletedCount = 0
        for fileURL in entries {
            let filename = fileURL.lastPathComponent
            // Skip tier-suffixed files (id@thumb, id@hero) — those are streaming cache
            // managed by ArtworkImageCache's own eviction, not offline-download GC.
            guard !filename.contains("@") else { continue }
            let coverArtId = filename
            if !referencedIds.contains(coverArtId) {
                do {
                    try fm.removeItem(at: fileURL)
                } catch {
                    Logger.download.debug("DownloadService: garbageCollect removeItem failed — \(error)")
                }
                deletedCount += 1
            }
        }
        if deletedCount > 0 {
            Logger.download.info("Garbage collected \(deletedCount) orphaned cover(s).")
        }
        return deletedCount
    }

    func localAlbumData(albumId: String, serverId: UUID) async -> LocalAlbumData? {
        await offlineLibraryReader.localAlbumData(albumId: albumId, serverId: serverId)
    }

    func localArtistData(artistId: String, artistName: String?, serverId: UUID) async -> LocalArtistData? {
        await offlineLibraryReader.localArtistData(
            artistId: artistId,
            artistName: artistName,
            serverId: serverId
        )
    }

    func localPlaylistData(playlistId: String, serverId: UUID) async -> LocalPlaylistData? {
        await offlineLibraryReader.localPlaylistData(
            playlistId: playlistId,
            serverId: serverId
        )
    }

    func backfillPlaylistSongIds(playlistId: String, serverId: UUID, orderedSongIds: [String]) async {
        await offlineLibraryReader.backfillPlaylistSongIds(
            playlistId: playlistId,
            serverId: serverId,
            orderedSongIds: orderedSongIds
        )
    }

    // MARK: - Single track download

    func download(song: Song, serverId: UUID) async throws {
        guard !isRemovingAllDownloads else { throw CancellationError() }
        guard await !isDownloaded(songId: song.id, serverId: serverId) else {
            Logger.download.debug("Song '\(song.id, privacy: .public)' already downloaded — skipping.")
            return
        }
        guard !isRemovingAllDownloads else { throw CancellationError() }

        let key = taskKey(songId: song.id, serverId: serverId)
        // Every caller must observe the real result. Returning immediately used to make
        // overlapping album/playlist requests count a still-running (or later failing)
        // transfer as a success.
        if let existing = inFlightTasks[key] {
            try await existing.value
            return
        }

        let task = Task<Void, Error> {
            try await self._downloadSong(song, serverId: serverId, key: key)
        }
        inFlightTasks[key] = task
        try await task.value
    }

    private func _downloadSong(_ song: Song, serverId: UUID, key: String) async throws {
        defer { inFlightTasks.removeValue(forKey: key) }

        let creds = try await serverService.activeCredentials()
        let client = try await serverService.makeSwiftSonicClient()
        guard let streamURL = client.streamURL(id: song.id) else {
            throw MinidiscError.mediaNotFound(songId: song.id)
        }

        var request = URLRequest(url: streamURL)
        for (k, v) in creds.customHeaders { request.setValue(v, forHTTPHeaderField: k) }

        emit(progress: DownloadProgress(songId: song.id, serverId: serverId, progress: 0, totalBytes: nil, receivedBytes: 0))

        let (tempURL, response) = try await downloadSession.download(for: request)

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            struct HTTPError: Error & Sendable { let statusCode: Int }
            throw MinidiscError.downloadFailed(songId: song.id, underlying: HTTPError(statusCode: code))
        }

        // Never save a poisoned payload as a permanent download (Subsonic error-as-200
        // envelope, empty or truncated body) — unlike the cache it is never evicted,
        // so a broken file would play as silence forever.
        do {
            try AudioResponseValidator.validate(fileAt: tempURL, response: response, songId: song.id, logger: Logger.download)
        } catch {
            throw MinidiscError.downloadFailed(songId: song.id, underlying: error)
        }

        let mimeType = response.mimeType ?? "audio/mpeg"
        // Name the file after what it IS, not what the server says it is. Navidrome has been observed
        // declaring suffix "m4a" while sending FLAC bytes; the extension is what the playback engine
        // picks its parser from, so the wrong one makes a healthy file unplayable — it goes to the m4a
        // parser, which finds no ftyp and reports end-of-track instantly.
        // Falls back to the server-declared suffix (then the MIME subtype) when the bytes match nothing
        // known. audio/mpeg → "mpeg", which AVPlayer maps to a video UTI, hence the suffix preference.
        let sniffed = AudioContainer.sniff(atPath: tempURL.path)
        if let sniffed, let declared = song.suffix?.lowercased(), sniffed.rawValue != declared {
            Logger.download.warning("Container mismatch for '\(song.id, privacy: .public)': server declared '\(declared, privacy: .public)', bytes are \(sniffed.rawValue, privacy: .public) — naming the file after the bytes")
        }
        let ext = sniffed?.rawValue ?? song.suffix ?? mimeType.split(separator: "/").last.map(String.init) ?? "bin"
        let relativePath = "\(serverId.uuidString)/\(song.id).\(ext)"
        let fileURL = downloadsDirectory.appendingPathComponent(relativePath)

        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: fileURL)

        // Faststart-remux non-faststart m4a in place so it keeps a streamable faststart layout
        // (lossless passthrough; no-op for every other format). MUST run before the fileSize
        // read below so DownloadedTrack.fileSize matches the on-disk (remuxed) file — otherwise
        // downloadedURL's size-validity guard would reject the remuxed file as a mismatch.
        // Logged for every outcome, not just .remuxed: knowing the remuxer ran and decided to do
        // nothing is what distinguishes "the file was already fine" from "the remuxer never fired".
        let remuxOutcome = await AudioFaststartRemuxer().remuxToFaststartIfNeeded(at: fileURL, container: sniffed?.rawValue)
        Logger.download.info("Remux outcome v\(AudioFaststartRemuxer.diagnosticsVersion) for '\(song.id, privacy: .public)' (suffix: \(song.suffix ?? "nil", privacy: .public)): \(String(describing: remuxOutcome), privacy: .public)")

        // Capture only Sendable values for the MainActor closure.
        let songId = song.id
        let albumId = song.albumId
        let artistId = song.artistId
        let title = song.title
        let artist = song.artist
        let album = song.album
        let genre = song.genres?.first?.name ?? song.genre
        let track = song.track
        let duration = song.duration
        let coverArtId = song.coverArt
        let suffix = song.suffix
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
        let rgTrackGain    = song.replayGain?.trackGain
        let rgTrackPeak    = song.replayGain?.trackPeak
        let rgAlbumGain    = song.replayGain?.albumGain
        let rgAlbumPeak    = song.replayGain?.albumPeak
        let rgBaseGain     = song.replayGain?.baseGain
        let rgFallbackGain = song.replayGain?.fallbackGain

        // Best-effort: persist cover art so it's available offline (compilations, playlist tracks).
        // song.coverArt may differ from album.coverArt on some servers — download it per track.
        // _downloadCoverArt is idempotent (physical file check), so no redundant network hit
        // when all tracks in a standard album share the same coverArtId.
        if let cid = coverArtId {
            do {
                try await _downloadCoverArt(id: cid)
            } catch {
                Logger.download.error("Cover art download failed for song '\(songId, privacy: .public)' (coverArtId: \(cid, privacy: .public)): \(error, privacy: .public)")
            }
        }

        await MainActor.run {
            let record = DownloadedTrack(
                songId: songId,
                serverId: serverId,
                albumId: albumId,
                filePath: relativePath,
                fileSize: fileSize,
                mimeType: mimeType,
                title: title,
                artist: artist,
                artistId: artistId,
                album: album,
                trackNumber: track,
                durationSeconds: duration,
                coverArtId: coverArtId,
                suffix: suffix,
                genre: genre,
                replayGainTrackGain: rgTrackGain,
                replayGainTrackPeak: rgTrackPeak,
                replayGainAlbumGain: rgAlbumGain,
                replayGainAlbumPeak: rgAlbumPeak,
                replayGainBaseGain: rgBaseGain,
                replayGainFallbackGain: rgFallbackGain
            )
            modelContainer.mainContext.insert(record)
            do {
                try modelContainer.mainContext.save()
            } catch {
                Logger.download.error("DownloadService: track record save failed for '\(songId, privacy: .public)' — \(error)")
            }
        }

        emit(progress: DownloadProgress(songId: song.id, serverId: serverId, progress: 1.0, totalBytes: fileSize, receivedBytes: fileSize))
        Logger.download.info("Downloaded '\(song.id, privacy: .public)' (\(fileSize) bytes)")
    }

    // MARK: - Album download

    func download(album: AlbumID3, serverId: UUID) async throws {
        guard let songs = album.song else { return }
        guard !isRemovingAllDownloads else { throw CancellationError() }
        activeAlbumDownloads.insert(album.id)
        defer { activeAlbumDownloads.remove(album.id) }
        let total = songs.count
        var succeeded = 0
        let aid = album.id

        let maxConcurrent = 3
        await withTaskGroup(of: Bool.self) { group in
            var iterator = songs.makeIterator()

            for _ in 0..<maxConcurrent {
                guard let song = iterator.next() else { break }
                group.addTask {
                    do {
                        try await self.download(song: song, serverId: serverId)
                        return true
                    } catch {
                        Logger.download.error("Failed song '\(song.id, privacy: .public)' in album '\(aid, privacy: .public)': \(error, privacy: .public)")
                        return false
                    }
                }
            }

            for await didSucceed in group {
                if didSucceed { succeeded += 1 }
                if !isRemovingAllDownloads, let song = iterator.next() {
                    group.addTask {
                        do {
                            try await self.download(song: song, serverId: serverId)
                            return true
                        } catch {
                            Logger.download.error("Failed song '\(song.id, privacy: .public)' in album '\(aid, privacy: .public)': \(error, privacy: .public)")
                            return false
                        }
                    }
                }
            }
        }
        guard !isRemovingAllDownloads else { throw CancellationError() }

        var localCoverPath: String? = nil
        if let coverArtId = album.coverArt {
            do {
                try await _downloadCoverArt(id: coverArtId)
                localCoverPath = coverArtId
            } catch {
                Logger.download.error("Cover art download failed for album '\(album.id, privacy: .public)' (coverArtId: \(coverArtId, privacy: .public)): \(error, privacy: .public)")
            }
        }
        guard !isRemovingAllDownloads else { throw CancellationError() }

        let albumId = album.id
        let albumName = album.name
        let albumArtist = album.artist
        let coverArt = album.coverArt
        let tracksSucceeded = succeeded
        let totalTracks = total
        let coverPath = localCoverPath

        await MainActor.run {
            let context = ModelContext(modelContainer)
            let existing = (try? context.fetch(FetchDescriptor<DownloadedAlbum>()))?
                .first(where: { $0.albumId == albumId && $0.serverId == serverId })

            if let existing {
                existing.tracksCount = tracksSucceeded
                existing.totalTracksCount = totalTracks
                existing.downloadedAt = Date()
                if let coverPath { existing.localCoverArtPath = coverPath }
            } else {
                let record = DownloadedAlbum(
                    albumId: albumId,
                    serverId: serverId,
                    name: albumName,
                    artist: albumArtist,
                    tracksCount: tracksSucceeded,
                    totalTracksCount: totalTracks,
                    coverArtId: coverArt,
                    localCoverArtPath: coverPath
                )
                context.insert(record)
            }
            do {
                try context.save()
            } catch {
                Logger.download.debug("DownloadService: album record save failed — \(error)")
            }
        }
        Logger.download.info("Album '\(album.id, privacy: .public)': \(succeeded)/\(total) tracks downloaded.")
        if succeeded == total {
            await toastService.showSuccess(String(localized: "\(album.name) downloaded"))
        }
    }

    // MARK: - Playlist download

    func download(playlist: PlaylistWithSongs, serverId: UUID) async throws {
        guard !isRemovingAllDownloads else { throw CancellationError() }
        let songs = playlist.entry ?? []
        let total = songs.count
        let pid = playlist.id
        activePlaylistDownloads.insert(playlist.id)
        defer { activePlaylistDownloads.remove(playlist.id) }

        let maxConcurrent = 3
        await withTaskGroup(of: Void.self) { group in
            var iterator = songs.makeIterator()

            for _ in 0..<maxConcurrent {
                guard let song = iterator.next() else { break }
                group.addTask {
                    do {
                        try await self.download(song: song, serverId: serverId)
                    } catch {
                        Logger.download.error("Failed song '\(song.id, privacy: .public)' in playlist '\(pid, privacy: .public)': \(error, privacy: .public)")
                    }
                }
            }

            for await _ in group {
                if !isRemovingAllDownloads, let song = iterator.next() {
                    group.addTask {
                        do {
                            try await self.download(song: song, serverId: serverId)
                        } catch {
                            Logger.download.error("Failed song '\(song.id, privacy: .public)' in playlist '\(pid, privacy: .public)': \(error, privacy: .public)")
                        }
                    }
                }
            }
        }
        guard !isRemovingAllDownloads else { throw CancellationError() }

        let downloadedIds = await downloadedSongIds(serverId: serverId)
        guard !isRemovingAllDownloads else { throw CancellationError() }
        let succeededIds = songs.filter { downloadedIds.contains($0.id) }.map(\.id)

        var localCoverPath: String? = nil
        if let coverArtId = playlist.coverArt {
            do {
                try await _downloadCoverArt(id: coverArtId)
                localCoverPath = coverArtId
            } catch {
                Logger.download.error("Cover art download failed for playlist '\(playlist.id, privacy: .public)' (coverArtId: \(coverArtId, privacy: .public)): \(error, privacy: .public)")
            }
        }
        guard !isRemovingAllDownloads else { throw CancellationError() }

        let playlistId = playlist.id
        let playlistName = playlist.name
        let comment = playlist.comment
        let coverArt = playlist.coverArt
        let tracksSucceeded = succeededIds.count
        let totalTracks = total
        let ids = succeededIds
        let coverPath = localCoverPath

        await MainActor.run {
            let context = ModelContext(modelContainer)
            let existing = (try? context.fetch(FetchDescriptor<DownloadedPlaylist>()))?
                .first(where: { $0.playlistId == playlistId && $0.serverId == serverId })

            if let existing {
                existing.tracksCount = tracksSucceeded
                existing.totalTracksCount = totalTracks
                existing.downloadedAt = Date()
                existing.songIds = ids
                if let coverPath { existing.localCoverArtPath = coverPath }
            } else {
                let record = DownloadedPlaylist(
                    playlistId: playlistId,
                    serverId: serverId,
                    name: playlistName,
                    comment: comment,
                    tracksCount: tracksSucceeded,
                    totalTracksCount: totalTracks,
                    coverArtId: coverArt,
                    localCoverArtPath: coverPath,
                    songIds: ids
                )
                context.insert(record)
            }
            do {
                try context.save()
            } catch {
                Logger.download.debug("DownloadService: playlist record save failed — \(error)")
            }
        }
        Logger.download.info("Playlist '\(playlist.id, privacy: .public)': \(tracksSucceeded)/\(total) tracks downloaded.")
        if tracksSucceeded == totalTracks {
            await toastService.showSuccess(String(localized: "\(playlist.name) downloaded"))
        }
    }

    func isDownloading(songId: String, serverId: UUID) async -> Bool {
        inFlightTasks[taskKey(songId: songId, serverId: serverId)] != nil
    }

    func isDownloadingAlbum(_ albumId: String) async -> Bool {
        activeAlbumDownloads.contains(albumId)
    }

    func isDownloadingPlaylist(_ playlistId: String) async -> Bool {
        activePlaylistDownloads.contains(playlistId)
    }

    // MARK: - Cancel

    func cancelDownload(songId: String, serverId: UUID) async {
        let key = taskKey(songId: songId, serverId: serverId)
        inFlightTasks[key]?.cancel()
        // _downloadSong owns removal in its defer. Removing here opened a race where an
        // immediate retry installed a new task, then the cancelled old task's defer removed
        // the new entry and made cancellation/deduplication state lie.
    }

    // MARK: - Remove

    func remove(songId: String, serverId: UUID) async throws {
        try await offlineRemovalCoordinator.remove(.track(songId: songId), serverId: serverId)
    }

    func remove(albumId: String, serverId: UUID) async throws {
        try await offlineRemovalCoordinator.remove(.album(albumId: albumId), serverId: serverId)
    }

    func remove(playlistId: String, serverId: UUID) async throws {
        try await offlineRemovalCoordinator.remove(.playlist(playlistId: playlistId), serverId: serverId)
    }

    func removeAll() async throws {
        guard !isRemovingAllDownloads else { return }
        isRemovingAllDownloads = true
        defer { isRemovingAllDownloads = false }

        let tasks = Array(inFlightTasks.values)
        tasks.forEach { $0.cancel() }
        for task in tasks {
            _ = try? await task.value
        }

        try await offlineRemovalCoordinator.removeAll()
    }

    // MARK: - Helpers

    private func taskKey(songId: String, serverId: UUID) -> String {
        "\(songId)::\(serverId.uuidString)"
    }

    private func emit(progress: DownloadProgress) {
        progressContinuation?.yield([progress])
    }

    /// Downloads a cover art image to `coverArtsDirectory/<id>`. No-op if the file already exists.
    /// Throws on network or write error — callers must catch and treat as best-effort.
    private func _downloadCoverArt(id: String) async throws {
        let fileURL = coverArtsDirectory.appendingPathComponent(id)
        guard !FileManager.default.fileExists(atPath: fileURL.path) else {
            Logger.download.debug("Cover art '\(id, privacy: .public)' already on disk — skipping.")
            return
        }

        let creds = try await serverService.activeCredentials()
        let client = try await serverService.makeSwiftSonicClient()
        guard let artURL = client.coverArtURL(id: id, size: 600) else {
            throw MinidiscError.mediaNotFound(songId: id)
        }

        var request = URLRequest(url: artURL)
        for (k, v) in creds.customHeaders { request.setValue(v, forHTTPHeaderField: k) }

        let (data, response) = try await downloadSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            struct HTTPError: Error & Sendable { let statusCode: Int }
            throw MinidiscError.downloadFailed(songId: id, underlying: HTTPError(statusCode: code))
        }

        try FileManager.default.createDirectory(at: coverArtsDirectory, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        Logger.download.info("Cover art '\(id, privacy: .public)' downloaded (\(data.count) bytes)")
    }
}
