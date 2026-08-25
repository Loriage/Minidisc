import Foundation
import SwiftSonic

/// Backs the virtual "Recently Added" screen. There is no server playlist behind it — the track list is
/// rebuilt from the newest albums on every load, so it always reflects what the library holds now.
@Observable
@MainActor
final class RecentlyAddedViewModel {
    var songs: [DisplayableSong] = []
    var isLoading = true
    var error: UserFacingError?
    /// True while the bulk download is walking the track list.
    var isDownloadingAll = false
    var downloadingIds: Set<String> = []

    /// Cover of the newest album — the hero falls back to it when the caller had no cover to pass in.
    var coverArtId: String? { rawSongs.first?.coverArt }

    /// The fetched payload kept in its server form — `download(song:)` takes a SwiftSonic `Song`, and
    /// `DisplayableSong` can't be converted back.
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

    /// Downloads the whole list track by track.
    ///
    /// Deliberately NOT `download(playlist:)`: that persists a `DownloadedPlaylist` record keyed on a server
    /// playlist id, and this playlist has none. The tracks land as ordinary individual downloads — playable
    /// offline from the artist and album screens like any other — and the list itself stays purely derived.
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
