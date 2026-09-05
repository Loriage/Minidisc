import Foundation
import SwiftSonic

enum AddToPlaylistResult { case added, duplicate, failed }

@MainActor
@Observable
final class AddToPlaylistViewModel {
    private(set) var playlists: [Playlist] = []
    private(set) var isLoading = false
    private(set) var addingToPlaylistIds: Set<String> = []
    private(set) var error: UserFacingError?
    private(set) var recentIDs: [String]
    private(set) var createdPlaylist: Playlist?
    private(set) var isCreating = false
    var newPlaylistName = ""
    let songs: [DisplayableSong]

    private let playlistService: any PlaylistServiceProtocol
    private let toastService: ToastService
    private let recents: RecentPlaylistDestinations
    private var intents: [String: PlaylistAppendIntent] = [:]
    private var completed: Set<String> = []

    init(songs: [DisplayableSong], playlistService: any PlaylistServiceProtocol,
         toastService: ToastService, recents: RecentPlaylistDestinations) {
        self.songs = songs
        self.playlistService = playlistService
        self.toastService = toastService
        self.recents = recents
        self.recentIDs = recents.ids
    }

    var isSaving: Bool { isCreating || !addingToPlaylistIds.isEmpty }
    var canCreate: Bool { !newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSaving }

    func destinations(query: String, recent: Bool) -> [Playlist] {
        let query = LibrarySearchRanking.normalized(query)
        let filtered = playlists.filter { query.isEmpty || LibrarySearchRanking.normalized($0.name).contains(query) }
        if recent { return recentIDs.compactMap { id in filtered.first { $0.id == id } } }
        return filtered.filter { !recentIDs.contains($0.id) }.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do { playlists = try await playlistService.listPlaylists() }
        catch { report(error) }
    }

    func checkAndAdd(to playlist: Playlist) async -> AddToPlaylistResult {
        await add(to: playlist, duplicatePolicy: nil)
    }

    @discardableResult
    func forceAdd(to playlist: Playlist, skippingDuplicates: Bool = false) async -> Bool {
        await add(to: playlist, duplicatePolicy: skippingDuplicates) == .added
    }

    /// Retry finishes the created playlist after an append failure, keeping its name and selection.
    func createAndAdd() async -> Bool {
        guard canCreate else { return false }
        error = nil
        if createdPlaylist == nil {
            isCreating = true
            do {
                let created = try await playlistService.createPlaylist(
                    name: newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines), description: nil)
                let summary = Playlist(id: created.id, name: created.name, songCount: created.songCount,
                                       duration: created.duration, comment: created.comment, owner: created.owner,
                                       isPublic: created.isPublic, created: created.created,
                                       changed: created.changed, coverArt: created.coverArt)
                createdPlaylist = summary
                playlists.insert(summary, at: 0)
                intents[summary.id] = PlaylistAppendIntent(songs: songs, existingIDs: created.entry?.map(\.id) ?? [])
            } catch { report(error) }
            isCreating = false
        }
        guard let createdPlaylist else { return false }
        return await forceAdd(to: createdPlaylist)
    }

    /// nil asks for a decision; true skips existing IDs; false preserves requested occurrences.
    private func add(to playlist: Playlist, duplicatePolicy: Bool?) async -> AddToPlaylistResult {
        guard !songs.isEmpty, !isSaving else { return .failed }
        if completed.contains(playlist.id) { return .added }
        addingToPlaylistIds.insert(playlist.id)
        error = nil
        defer { addingToPlaylistIds.remove(playlist.id) }
        do {
            // Refresh server detail, including after an ambiguous append failure.
            let current = try await playlistService.getPlaylist(id: playlist.id)
            let ids = current.entry?.map(\.id) ?? []
            if intents[playlist.id] == nil {
                let existing = Set(ids)
                if duplicatePolicy == nil, songs.contains(where: { existing.contains($0.id) }) { return .duplicate }
                let desired = duplicatePolicy == true ? songs.filter { !existing.contains($0.id) } : songs
                intents[playlist.id] = PlaylistAppendIntent(songs: desired, existingIDs: ids)
            }
            guard let intent = intents[playlist.id] else { return .failed }
            let remaining = intent.remaining(after: ids)
            if !remaining.isEmpty {
                try await playlistService.addTracks(playlistId: playlist.id, songs: remaining.map { $0.asSong() })
            }
            completed.insert(playlist.id)
            recents.record(playlist.id)
            recentIDs = recents.ids
            let message = intent.songs.isEmpty ? String(localized: "These songs are already in the playlist.")
                : String(localized: "\(intent.songs.count) songs added")
            toastService.showConfirmation(message, subtitle: playlist.name, coverArtId: playlist.coverArt,
                action: .navigateToPlaylist(id: playlist.id, name: playlist.name, coverArtId: playlist.coverArt))
            return .added
        } catch {
            report(error)
            return .failed
        }
    }

    private func report(_ error: Error) {
        guard !UserFacingError.isCancellation(error) else { return }
        self.error = UserFacingError.from(error)
    }
}
