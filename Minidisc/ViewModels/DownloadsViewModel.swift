import Foundation
import OSLog
import SwiftData

nonisolated struct DownloadedPlaylistDTO: Identifiable, Sendable {
    let id: UUID
    let playlistId: String
    let serverId: UUID
    let name: String
    let tracksCount: Int
    let totalTracksCount: Int
    var isComplete: Bool { tracksCount == totalTracksCount }
}

@Observable
@MainActor
final class DownloadsViewModel {
    var displayAlbums: [DownloadedAlbumDisplay] = []
    var downloadedPlaylists: [DownloadedPlaylistDTO] = []
    var usedBytesFormatted: String = "—"
    var trackCount: Int = 0
    var isClearingAll = false

    private let modelContainer: ModelContainer
    private let downloadService: any DownloadServiceProtocol
    private let serverState: ServerState

    init(
        modelContainer: ModelContainer,
        downloadService: any DownloadServiceProtocol,
        serverState: ServerState
    ) {
        self.modelContainer = modelContainer
        self.downloadService = downloadService
        self.serverState = serverState
    }

    func loadData() async {
        let context = ModelContext(modelContainer)
        let albums = (try? context.fetch(FetchDescriptor<DownloadedAlbum>())) ?? []
        let playlists = (try? context.fetch(FetchDescriptor<DownloadedPlaylist>())) ?? []
        let tracks = (try? context.fetch(FetchDescriptor<DownloadedTrack>())) ?? []

        displayAlbums = DownloadedAlbumMerger.merge(records: albums, tracks: tracks)

        downloadedPlaylists = playlists.map {
            DownloadedPlaylistDTO(
                id: $0.id,
                playlistId: $0.playlistId,
                serverId: $0.serverId,
                name: $0.name,
                tracksCount: $0.tracksCount,
                totalTracksCount: $0.totalTracksCount
            )
        }

        let totalBytes = tracks.map(\.fileSize).reduce(0, +)
        usedBytesFormatted = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        trackCount = tracks.count
    }

    func removeAlbum(_ display: DownloadedAlbumDisplay) async {
        // DownloadService applies the same reference-counting rules whether or not a
        // DownloadedAlbum intent record exists. Deleting inferred tracks one by one
        // bypassed those rules and could break a downloaded playlist sharing them.
        try? await downloadService.remove(albumId: display.albumId, serverId: display.serverId)
        await loadData()
    }

    func removePlaylist(_ dto: DownloadedPlaylistDTO) async {
        try? await downloadService.remove(playlistId: dto.playlistId, serverId: dto.serverId)
        await loadData()
    }

    func clearAll() async {
        isClearingAll = true
        defer { isClearingAll = false }

        do {
            try await downloadService.removeAll()
        } catch {
            Logger.download.error("Failed to clear offline library: \(error, privacy: .public)")
        }
        await loadData()
    }
}
