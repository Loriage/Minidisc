import Foundation
import SwiftSonic

@Observable
@MainActor
final class ArtistBestOfViewModel {
    var songs: [DisplayableSong] = []
    var isLoading = true
    var error: UserFacingError?
    var isDownloadingAll = false
    var downloadingIds: Set<String> = []

    private var rawSongs: [Song] = []

    private let artistId: String
    private let artistName: String
    private let libraryService: any StarredBrowsing
    private let downloadService: any DownloadServiceProtocol
    private let serverState: ServerState

    init(
        artistId: String,
        artistName: String,
        libraryService: any StarredBrowsing,
        downloadService: any DownloadServiceProtocol,
        serverState: ServerState
    ) {
        self.artistId = artistId
        self.artistName = artistName
        self.libraryService = libraryService
        self.downloadService = downloadService
        self.serverState = serverState
    }

    func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let starred = try await libraryService.getStarred2()
            rawSongs = (starred.song ?? []).filter {
                ArtistBestOf.matches($0, artistId: artistId, artistName: artistName)
            }
            songs = ArtistBestOf.songs(of: artistId, named: artistName, in: starred.song ?? [])
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
