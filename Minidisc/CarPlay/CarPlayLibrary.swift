import Foundation
import SwiftSonic

nonisolated enum CarPlayRoute: Hashable, Sendable {
    case recent, albums, artists, songs, playlists, favorites
    case songPage(offset: Int)
    case album(String), artist(String), playlist(String)
}

nonisolated struct CarPlayCollection: Sendable {
    let title: String
    let subtitle: String?
    let artworkID: String?
    let route: CarPlayRoute

    init(album: AlbumID3) {
        title = album.name; subtitle = album.artist; artworkID = album.coverArt; route = .album(album.id)
    }
    init(artist: ArtistID3) {
        title = artist.name; subtitle = nil; artworkID = artist.coverArt; route = .artist(artist.id)
    }
    init(playlist: Playlist) {
        title = playlist.name; subtitle = nil; artworkID = playlist.coverArt; route = .playlist(playlist.id)
    }
}

nonisolated struct CarPlayContext: Equatable, Sendable {
    let serverID: UUID?
    let access: ServerAccessSnapshot
}

nonisolated struct CarPlayContent: Sendable {
    let context: CarPlayContext
    var collections: [CarPlayCollection] = []
    var songs: [DisplayableSong] = []
    var showingOfflineFallback = false
    var previousPage: CarPlayRoute?
    var nextPage: CarPlayRoute?
}

typealias CarPlayLibrarySource = AlbumBrowsing & ArtistBrowsing & SongBrowsing
    & PlaylistBrowsing & RecentlyAddedAlbumBrowsing & StarredBrowsing

/// CarPlay reads the same sources as the phone without requiring a SwiftUI window to exist.
/// A result and every action derived from it belong to one server/account/access context.
@MainActor
final class CarPlayLibrary {
    private let server: ServerState
    private let source: any CarPlayLibrarySource
    private let localStore: LocalMusicStore
    private let readOffline: @Sendable (UUID) async throws -> OfflineBrowsingSnapshot

    init(server: ServerState, source: any CarPlayLibrarySource, localStore: LocalMusicStore,
         readOffline: @escaping @Sendable (UUID) async throws -> OfflineBrowsingSnapshot) {
        self.server = server; self.source = source; self.localStore = localStore; self.readOffline = readOffline
    }

    convenience init(container: AppContainer) {
        self.init(server: container.serverState, source: container.libraryService,
                  localStore: container.localMusic.store,
                  readOffline: { [reader = container.offlineBrowsingReader] in try await reader.read(serverID: $0) })
    }

    var context: CarPlayContext {
        CarPlayContext(serverID: server.activeServer?.id, access: server.accessSnapshot)
    }

    func validate(_ expected: CarPlayContext) throws {
        try Task.checkCancellation()
        guard expected == context else { throw CancellationError() }
    }

    func load(_ route: CarPlayRoute, songLimit: Int = 500) async throws -> CarPlayContent {
        let expected = context
        let local = LocalMusicCatalog(tracks: await localStore.current().tracks.filter(\.isAvailable))
        try validate(expected)
        if case .album(let id) = route, LocalMusicCatalog.isCollectionID(id) {
            return CarPlayContent(context: expected, songs: local.groups[id]?.tracks.map(\.song) ?? [])
        }
        if case .artist(let id) = route, LocalMusicCatalog.isCollectionID(id) {
            return CarPlayContent(context: expected, songs: local.groups[id]?.tracks.map(\.song) ?? [])
        }
        var result = CarPlayContent(context: expected)
        if let serverID = expected.serverID {
            if expected.access.isOnline {
                do {
                    result = try await online(route, context: expected, songLimit: songLimit)
                } catch {
                    if UserFacingError.isCancellation(error) { throw CancellationError() }
                    try validate(expected)
                    let offline = try? await readOffline(serverID)
                    result = offlineContent(route, snapshot: offline ?? OfflineBrowsingSnapshot(), context: expected)
                    result.showingOfflineFallback = true
                }
            } else {
                let snapshot = try? await readOffline(serverID)
                result = offlineContent(route, snapshot: snapshot ?? OfflineBrowsingSnapshot(), context: expected)
                result.showingOfflineFallback = snapshot == nil
            }
        }
        try validate(expected)
        switch route {
        case .recent:
            let recent = local.albums.sorted { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }
            result.collections.insert(contentsOf: recent.map(CarPlayCollection.init(album:)), at: 0)
        case .albums:
            result.collections += local.albums.map(CarPlayCollection.init(album:))
        case .artists:
            result.collections += local.artists.map(CarPlayCollection.init(artist:))
        case .songs:
            result.songs += local.songs
            result.songs.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .songPage where result.showingOfflineFallback:
            result.songs += local.songs
        default: break
        }
        if route == .albums || route == .artists || route == .playlists {
            result.collections.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
        return result
    }

    /// Re-check availability at the moment of selection while preserving duplicates and queue order.
    /// The player calls this inside its prepared-queue transaction, so a later Pause/Play wins.
    func preparePlayback(_ content: CarPlayContent, index: Int,
                         shuffled: Bool = false) async throws -> PreparedPlaybackQueue {
        try validate(content.context)
        guard content.songs.indices.contains(index) else { throw LocalMusicError.unavailable }
        let local = LocalMusicCatalog(tracks: await localStore.current().tracks)
        let offline: OfflineBrowsingSnapshot?
        if !content.context.access.isOnline, let id = content.context.serverID {
            offline = try await readOffline(id)
        } else { offline = nil }
        try validate(content.context)
        let available = content.songs.enumerated().filter { _, song in
            song.isLocalFile ? local.availableSongIDs.contains(song.id)
                : (content.context.serverID != nil && (offline == nil || offline!.songIDs.contains(song.id)))
        }
        guard let start = available.firstIndex(where: { $0.offset == index }) else { throw LocalMusicError.unavailable }
        return PreparedPlaybackQueue(tracks: available.map(\.element), startIndex: start,
                                     order: shuffled ? .shuffled : .ordered)
    }

    private func online(_ route: CarPlayRoute, context: CarPlayContext, songLimit: Int) async throws -> CarPlayContent {
        var content = CarPlayContent(context: context)
        switch route {
        case .recent: content.collections = try await source.recentlyAddedAlbums(size: 30).map(CarPlayCollection.init(album:))
        case .albums: content.collections = try await source.allAlbums().map(CarPlayCollection.init(album:))
        case .artists: content.collections = try await source.artists().flatMap(\.artist).map(CarPlayCollection.init(artist:))
        case .songs, .songPage:
            let offset: Int
            if case .songPage(let value) = route { offset = max(0, value) } else { offset = 0 }
            let count = max(1, songLimit)
            let songs = try await source.allSongs(offset: offset, count: count + 1)
            content.songs = songs.prefix(count).map { DisplayableSong(from: $0) }
            if songs.count > count { content.nextPage = .songPage(offset: offset + count) }
            if offset > 0 { content.previousPage = offset <= count ? .songs : .songPage(offset: offset - count) }
        case .playlists: content.collections = try await source.playlists().map(CarPlayCollection.init(playlist:))
        case .favorites: content.songs = try await (source.getStarred2().song ?? []).map { DisplayableSong(from: $0) }
        case .album(let id): content.songs = try await (source.album(id: id).song ?? []).map { DisplayableSong(from: $0) }
        case .artist(let id): content.collections = try await (source.artist(id: id).album ?? []).map(CarPlayCollection.init(album:))
        case .playlist(let id): content.songs = try await (source.playlist(id: id).entry ?? []).map { DisplayableSong(from: $0) }
        }
        return content
    }

    private func offlineContent(_ route: CarPlayRoute, snapshot: OfflineBrowsingSnapshot,
                                context: CarPlayContext) -> CarPlayContent {
        var content = CarPlayContent(context: context)
        switch route {
        case .recent, .albums: content.collections = snapshot.albums.map(CarPlayCollection.init(album:))
        case .artists: content.collections = snapshot.artists.map(CarPlayCollection.init(artist:))
        case .songs, .songPage: content.songs = snapshot.songs
        case .playlists: content.collections = snapshot.playlists.map(CarPlayCollection.init(playlist:))
        case .favorites: content.songs = snapshot.favorites.songs.map { DisplayableSong(from: $0) }
        case .album(let id): content.songs = snapshot.albumSongs(id)
        case .artist(let id): content.songs = snapshot.artistSongs(id)
        case .playlist(let id): content.songs = snapshot.playlistSongs[id] ?? []
        }
        return content
    }
}
