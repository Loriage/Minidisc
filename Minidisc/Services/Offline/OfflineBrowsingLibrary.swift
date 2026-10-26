import Foundation
import Observation
import SwiftData
import SwiftSonic

nonisolated struct OfflineBrowsingSnapshot: Sendable {
    var songs: [DisplayableSong] = []
    var albums: [AlbumID3] = []
    var artists: [ArtistID3] = []
    var playlists: [Playlist] = []
    var playlistSongs: [String: [DisplayableSong]] = [:]
    var favorites = HomeFavorites()
    var songIDs: Set<String> = []
    var albumIDs: Set<String> = []
    var artistIDs: Set<String> = []
    var playlistIDs: Set<String> = []

    init(songs: [DisplayableSong] = [], playlists: [Playlist] = [], membership: [String: [String]] = [:], favorites: HomeFavorites = HomeFavorites()) {
        var seen = Set<String>()
        self.songs = songs.filter { seen.insert($0.id).inserted }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        songIDs = seen
        let byID = Dictionary(self.songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let byAlbum = Dictionary(grouping: self.songs.filter { $0.albumId != nil }, by: { $0.albumId! })
        albums = byAlbum.map { id, tracks in
            let first = tracks[0]
            return AlbumID3(id: id, name: first.albumName ?? id, songCount: tracks.count,
                            duration: Int(tracks.reduce(0) { $0 + $1.duration }), artist: first.artist,
                            artistId: first.artistId, coverArt: first.coverArtId,
                            song: Self.ordered(tracks).map { $0.asSong() })
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        albumIDs = Set(albums.map(\.id))
        let byArtist = Dictionary(grouping: self.songs.filter { $0.artistId != nil }, by: { $0.artistId! })
        artists = byArtist.map { id, tracks in
            let releases = albums.filter { $0.artistId == id }
            return ArtistID3(id: id, name: tracks[0].artist ?? id, albumCount: releases.count,
                             coverArt: tracks[0].coverArtId, album: releases)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        artistIDs = Set(artists.map(\.id))
        for playlist in playlists {
            let local = (membership[playlist.id] ?? []).compactMap { byID[$0] }
            guard !local.isEmpty, playlistIDs.insert(playlist.id).inserted else { continue }
            playlistSongs[playlist.id] = local
            self.playlists.append(Playlist(id: playlist.id, name: playlist.name, songCount: local.count,
                duration: Int(local.reduce(0) { $0 + $1.duration }), comment: playlist.comment,
                owner: playlist.owner, isPublic: playlist.isPublic, created: playlist.created,
                changed: playlist.changed, coverArt: playlist.coverArt))
        }
        self.favorites = HomeFavorites(songs: favorites.songs.filter { songIDs.contains($0.id) },
                                       albums: favorites.albums.filter { albumIDs.contains($0.id) },
                                       artists: favorites.artists.filter { artistIDs.contains($0.id) })
    }

    func albumSongs(_ id: String) -> [DisplayableSong] { Self.ordered(songs.filter { $0.albumId == id }) }
    func artistSongs(_ id: String) -> [DisplayableSong] { songs.filter { $0.artistId == id } }

    private static func ordered(_ songs: [DisplayableSong]) -> [DisplayableSong] {
        songs.sorted {
            if ($0.discNumber ?? 1) != ($1.discNumber ?? 1) { return ($0.discNumber ?? 1) < ($1.discNumber ?? 1) }
            return ($0.trackNumber ?? 0) < ($1.trackNumber ?? 0)
        }
    }
}

actor OfflineBrowsingReader {
    private let models: ModelContainer
    private let downloads: any DownloadServiceProtocol
    private let cache: AudioStreamCache
    private let favorites: OfflineFavoritesStore
    private let index: LibraryIndexStore

    init(models: ModelContainer, downloads: any DownloadServiceProtocol, cache: AudioStreamCache,
         favorites: OfflineFavoritesStore, index: LibraryIndexStore) {
        self.models = models; self.downloads = downloads; self.cache = cache
        self.favorites = favorites; self.index = index
    }

    func read(serverID: UUID) async throws -> OfflineBrowsingSnapshot {
        let validDownloads = await downloads.downloadedSongIds(serverId: serverID)
        let (manual, savedPlaylists, membership) = try await MainActor.run {
            let context = ModelContext(models)
            let tracks = try context.fetch(FetchDescriptor<DownloadedTrack>(predicate: #Predicate { $0.serverId == serverID }))
            let lists = try context.fetch(FetchDescriptor<DownloadedPlaylist>(predicate: #Predicate { $0.serverId == serverID }))
            return (tracks.filter { validDownloads.contains($0.songId) }.map { DisplayableSong(from: $0) },
                    lists.map { Playlist(id: $0.playlistId, name: $0.name, songCount: $0.tracksCount,
                                         duration: 0, coverArt: $0.coverArtId) },
                    Dictionary(lists.filter { !$0.songIds.isEmpty || $0.totalTracksCount == 0 }.map { ($0.playlistId, $0.songIds) }, uniquingKeysWith: { first, _ in first }))
        }
        let saved = try await favorites.snapshot(serverID: serverID)
        var automatic: [DisplayableSong] = []
        for song in saved.songs {
            try Task.checkCancellation()
            if await favorites.localURL(songID: song.id, serverID: serverID) != nil { automatic.append(DisplayableSong(from: song)) }
        }
        let availableCacheIDs = try await cache.availableSongIDs(serverID: serverID)
        let cachedSongs = try await index.songs(ids: availableCacheIDs, serverID: serverID).map { DisplayableSong(from: $0) }
        let indexedPlaylists = try await index.playlists(serverID: serverID)
        var members = membership
        for playlist in indexedPlaylists {
            try Task.checkCancellation()
            if members[playlist.id] == nil, let detail = try await index.playlist(id: playlist.id, serverID: serverID) {
                members[playlist.id] = (detail.playlist.entry ?? []).map(\.id)
            }
        }
        return OfflineBrowsingSnapshot(songs: manual + automatic + cachedSongs,
            playlists: savedPlaylists + indexedPlaylists, membership: members,
            favorites: HomeFavorites(songs: saved.favorites?.song ?? [], albums: saved.favorites?.album ?? [], artists: saved.favorites?.artist ?? []))
    }
}

@Observable @MainActor
final class OfflineBrowsingLibrary {
    struct Request: Equatable {
        let access: ServerAccessSnapshot
        let revision: Int
    }
    var request: Request { Request(access: state.accessSnapshot, revision: revision) }

    private let state: ServerState
    private let reader: OfflineBrowsingReader
    private var loadedServer: UUID?
    private var value = OfflineBrowsingSnapshot()
    private var generation = 0
    var revision = 0
    private(set) var isLoading = false

    var snapshot: OfflineBrowsingSnapshot {
        loadedServer == state.activeServer?.id ? value : OfflineBrowsingSnapshot()
    }

    init(state: ServerState, reader: OfflineBrowsingReader) { self.state = state; self.reader = reader }

    func refresh() async {
        generation += 1
        guard !state.isOnline, let id = state.activeServer?.id else {
            loadedServer = nil
            value = OfflineBrowsingSnapshot()
            isLoading = false
            return
        }
        let request = generation
        isLoading = true
        defer { if request == generation { isLoading = false } }
        guard let result = try? await reader.read(serverID: id), !Task.isCancelled,
              request == generation, state.activeServer?.id == id, !state.isOnline else { return }
        loadedServer = id
        value = result
    }
}

extension AppContainer {
    func visibleSongs(_ songs: [DisplayableSong]) -> [DisplayableSong] {
        serverState.isOnline ? songs : songs.filter { offlineLibrary.snapshot.songIDs.contains($0.id) }
    }
    func visibleAlbums(_ albums: [AlbumID3]) -> [AlbumID3] {
        serverState.isOnline ? albums : albums.filter { offlineLibrary.snapshot.albumIDs.contains($0.id) }
    }
    func visiblePlaylists(_ playlists: [Playlist]) -> [Playlist] {
        serverState.isOnline ? playlists : playlists.filter { offlineLibrary.snapshot.playlistIDs.contains($0.id) }
    }
}
