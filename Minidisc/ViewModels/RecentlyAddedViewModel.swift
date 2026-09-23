import Foundation
import SwiftSonic

@Observable
@MainActor
final class RecentlyAddedViewModel {
    var songs: [DisplayableSong] = []
    var isLoading = true
    var error: UserFacingError?
    var isDownloadingAll = false
    var downloadingIds: Set<String> = []

    var coverArtId: String? { rawSongs.first?.coverArt }

    private var rawSongs: [Song] = []

    private let libraryService: any RecentlyAddedTrackBrowsing
    private let downloadService: any DownloadServiceProtocol
    private let serverState: ServerState

    init(
        libraryService: any RecentlyAddedTrackBrowsing,
        downloadService: any DownloadServiceProtocol,
        serverState: ServerState
    ) {
        self.libraryService = libraryService
        self.downloadService = downloadService
        self.serverState = serverState
    }

    func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            rawSongs = try await libraryService.recentlyAddedTracks(
                albumLimit: RecentlyAdded.albumsToScan,
                trackLimit: RecentlyAdded.trackLimit
            )
            songs = rawSongs.map { DisplayableSong(from: $0) }
        } catch {
            self.error = UserFacingError.from(error)
        }
    }

    /// Download tracks individually: this virtual playlist has no server ID to persist.
    func downloadAll(songIds: [String]) async {
        isDownloadingAll = true
        defer { isDownloadingAll = false }
        await download(songIds: songIds)
    }

    func download(songIds: [String]) async {
        guard let serverId = serverState.activeServer?.id else { return }
        let byId = Dictionary(rawSongs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let alreadyDownloaded = await downloadService.downloadedSongIds(serverId: serverId)
        for id in songIds where !alreadyDownloaded.contains(id) {
            guard let song = byId[id] else { continue }
            downloadingIds.insert(id)
            try? await downloadService.download(song: song, serverId: serverId)
            downloadingIds.remove(id)
        }
    }

    func removeDownload(songId: String) async {
        guard let serverId = serverState.activeServer?.id else { return }
        try? await downloadService.remove(songId: songId, serverId: serverId)
    }
}
