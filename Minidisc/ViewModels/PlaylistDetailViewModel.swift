import Foundation
import SwiftUI
import SwiftSonic
import OSLog

@Observable
@MainActor
final class PlaylistDetailViewModel {
    var name: String = ""
    var owner: String? = nil
    var coverArtId: String? = nil
    var songs: [DisplayableSong] = []
    var isOffline: Bool = false
    var isLoading = false
    private(set) var isRemovedFromServer = false
    private var loadGeneration: UInt64 = 0
    private var lastValidatedAt: Date?
    var error: UserFacingError?
    private(set) var isMutatingTracks = false
    var isDownloadingPlaylist = false
    var downloadingIds: Set<String> = []

    private(set) var playlistDetail: PlaylistWithSongs?
    private let playlistId: String
    private let libraryService: any PlaylistBrowsing
    private let downloadService: any DownloadServiceProtocol
    private let playlistService: any PlaylistServiceProtocol
    private let toastService: ToastService
    private let serverState: ServerState
    private let offlineReader: OfflineBrowsingReader?

    init(
        playlistId: String,
        libraryService: any PlaylistBrowsing,
        downloadService: any DownloadServiceProtocol,
        playlistService: any PlaylistServiceProtocol,
        toastService: ToastService,
        serverState: ServerState,
        offlineReader: OfflineBrowsingReader? = nil
    ) {
        self.playlistId = playlistId
        self.libraryService = libraryService
        self.downloadService = downloadService
        self.playlistService = playlistService
        self.toastService = toastService
        self.serverState = serverState
        self.offlineReader = offlineReader
    }

    func load() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        guard let serverId = serverState.activeServer?.id else { return }
        isLoading = true
        error = nil
        defer { if generation == loadGeneration { isLoading = false } }

        // Draw the cached snapshot first; server validation continues without blanking the list.
        if songs.isEmpty, !isRemovedFromServer,
           let cached = await libraryService.cachedPlaylist(id: playlistId) {
            let downloaded = await downloadService.downloadedSongIds(serverId: serverId)
            guard isCurrent(generation, serverId: serverId) else { return }
            apply(cached, downloadedIDs: downloaded)
        }
        guard isCurrent(generation, serverId: serverId) else { return }
        if serverState.isOnline {
            do {
                let fresh = try await libraryService.refreshPlaylist(id: playlistId)
                let downloaded = await downloadService.downloadedSongIds(serverId: serverId)
                guard isCurrent(generation, serverId: serverId) else { return }
                isRemovedFromServer = false
                lastValidatedAt = .now
                // Keep intentional downloaded copies even when the remote playlist becomes empty.
                if (fresh.entry ?? []).isEmpty,
                   await loadFromLocal(generation: generation, serverId: serverId) { return }
                guard isCurrent(generation, serverId: serverId) else { return }
                apply(fresh, downloadedIDs: downloaded)
                isOffline = false
                await downloadService.backfillPlaylistSongIds(
                    playlistId: playlistId, serverId: serverId,
                    orderedSongIds: (fresh.entry ?? []).map(\.id)
                )
            } catch {
                guard isCurrent(generation, serverId: serverId),
                      !UserFacingError.isCancellation(error) else { return }
                if PlaylistAvailability.isConfirmedMissing(error) {
                    if !isRemovedFromServer { postPlaylistDeleted() }
                    isRemovedFromServer = true
                    playlistDetail = nil
                    songs = []
                    isOffline = true
                    _ = await loadFromLocal(generation: generation, serverId: serverId)
                } else if !(await loadFromLocal(generation: generation, serverId: serverId)) {
                    guard isCurrent(generation, serverId: serverId) else { return }
                    self.error = UserFacingError.from(error)
                }
            }
        } else {
            isOffline = true
            _ = await loadFromLocal(generation: generation, serverId: serverId)
        }
        let downloading = await downloadService.isDownloadingPlaylist(playlistId)
        guard isCurrent(generation, serverId: serverId) else { return }
        isDownloadingPlaylist = downloading
    }

    /// Revalidate an old screen before creating a new queue. A removed playlist never causes
    /// dozens of dead streams to be started; its downloaded copy remains playable.
    func playbackSongs(from requested: [DisplayableSong]) async -> [DisplayableSong] {
        if !serverState.isOnline, offlineReader != nil {
            await load()
        }
        if serverState.isOnline, lastValidatedAt.map({ Date().timeIntervalSince($0) > 30 }) ?? true {
            await load()
        }
        guard !Task.isCancelled else { return [] }
        let current = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return requested.compactMap { current[$0.id] }
    }

    func playbackQueue(entries: [PlaylistEntry], selectedID: PlaylistEntry.ID) async -> PreparedPlaybackQueue? {
        _ = await playbackSongs(from: entries.map(\.song))
        guard !Task.isCancelled else { return nil }
        return PlaylistEntry.playbackQueue(requested: entries, selectedID: selectedID, available: songs)
    }

    private func isCurrent(_ generation: UInt64, serverId: UUID) -> Bool {
        generation == loadGeneration && serverState.activeServer?.id == serverId && !Task.isCancelled
    }

    private func apply(_ playlist: PlaylistWithSongs, downloadedIDs: Set<String>) {
        playlistDetail = playlist
        name = playlist.name
        owner = playlist.owner
        coverArtId = playlist.coverArt
        songs = (playlist.entry ?? []).map { DisplayableSong(from: $0, isDownloaded: downloadedIDs.contains($0.id)) }
    }

    @discardableResult
    private func loadFromLocal(generation: UInt64, serverId: UUID) async -> Bool {
        if let offlineReader, let snapshot = try? await offlineReader.read(serverID: serverId),
           isCurrent(generation, serverId: serverId) {
            songs = snapshot.playlistSongs[playlistId] ?? []
            if let playlist = snapshot.playlists.first(where: { $0.id == playlistId }) {
                name = playlist.name; coverArtId = playlist.coverArt
            }
            isOffline = true
            return !songs.isEmpty
        }
        guard let data = await downloadService.localPlaylistData(playlistId: playlistId, serverId: serverId),
              isCurrent(generation, serverId: serverId), !data.songs.isEmpty else { return false }
        name = data.name
        coverArtId = data.coverArtId
        songs = data.songs
        isOffline = true
        return true
    }

    func downloadPlaylist() async {
        guard let playlist = playlistDetail, let serverId = serverState.activeServer?.id else { return }
        isDownloadingPlaylist = true
        defer { isDownloadingPlaylist = false }
        await toastService.perform { try await downloadService.download(playlist: playlist, serverId: serverId) }
        let downloadedIds = await downloadService.downloadedSongIds(serverId: serverId)
        guard serverState.activeServer?.id == serverId else { return }
        songs = songs.map { $0.withDownloaded(downloadedIds.contains($0.id)) }
        isDownloadingPlaylist = false
    }

    func cancelPlaylistDownload() async {
        guard let serverId = serverState.activeServer?.id else { return }
        guard await toastService.perform({ try await downloadService.cancelDownloads(playlistId: playlistId, serverId: serverId) }) else { return }
        isDownloadingPlaylist = false
    }

    func downloadSong(id: String) async {
        guard let song = playlistDetail?.entry?.first(where: { $0.id == id }),
              let serverId = serverState.activeServer?.id else { return }
        downloadingIds.insert(id)
        defer { downloadingIds.remove(id) }
        await toastService.perform { try await downloadService.download(song: song, serverId: serverId) }
        let allDownloaded = await downloadService.downloadedSongIds(serverId: serverId)
        if let idx = songs.firstIndex(where: { $0.id == id }) {
            songs[idx] = songs[idx].withDownloaded(allDownloaded.contains(id))
        }
    }

    func downloadMissingTracks() async {
        await downloadPlaylist()
    }

    func deleteDownload() async {
        guard let serverId = serverState.activeServer?.id else { return }
        // DownloadService owns reference counting. Removing every song first bypassed it
        // and deleted files still needed by downloaded albums or other playlists.
        guard await toastService.perform({ try await downloadService.remove(playlistId: playlistId, serverId: serverId) }) else { return }
        let downloadedIds = await downloadService.downloadedSongIds(serverId: serverId)
        guard serverState.activeServer?.id == serverId else { return }
        songs = songs.map { $0.withDownloaded(downloadedIds.contains($0.id)) }
    }

    func removeTrack(at index: Int) async {
        await removeTracks(at: IndexSet(integer: index))
    }

    func removeTracks(at indices: IndexSet, expectedSongIDs: [String]? = nil) async {
        guard !isMutatingTracks, !indices.isEmpty,
              indices.allSatisfy({ songs.indices.contains($0) }),
              expectedSongIDs.map({ $0 == songs.map(\.id) }) ?? true,
              let serverID = serverState.activeServer?.id else { return }
        isMutatingTracks = true
        defer { isMutatingTracks = false }
        let original = songs
        do {
            try await playlistService.removeTracks(playlistId: playlistId, indices: Array(indices))
            guard serverState.activeServer?.id == serverID else { return }
            if songs.map(\.id) == original.map(\.id) {
                songs = original.enumerated().filter { !indices.contains($0.offset) }.map(\.element)
            } else {
                await load()
            }
        } catch {
            Logger.playlist.error("PlaylistDetailViewModel: remove track failed: \(error)")
            if !UserFacingError.isCancellation(error) { toastService.showError("Failed to remove track") }
        }
    }

    func moveTracks(from source: IndexSet, to destination: Int) async {
        guard !isMutatingTracks, source.allSatisfy({ songs.indices.contains($0) }),
              (0...songs.count).contains(destination), let serverID = serverState.activeServer?.id else { return }
        isMutatingTracks = true
        defer { isMutatingTracks = false }
        let original = songs
        var reordered = original
        reordered.move(fromOffsets: source, toOffset: destination)
        do {
            try await playlistService.reorderTracks(playlistId: playlistId, orderedSongIds: reordered.map(\.id))
            guard serverState.activeServer?.id == serverID else { return }
            if songs.map(\.id) == original.map(\.id) { songs = reordered }
            else { await load() }
        } catch {
            Logger.playlist.error("PlaylistDetailViewModel: reorder failed: \(error)")
            if !UserFacingError.isCancellation(error) { toastService.showError("Failed to reorder tracks") }
        }
    }
}
