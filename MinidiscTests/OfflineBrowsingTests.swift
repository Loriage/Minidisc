import Foundation
import SwiftData
import SwiftSonic
import Testing
@testable import Minidisc

@Suite("Offline browsing") @MainActor
struct OfflineBrowsingTests {
    private func song(_ id: String, album: String = "album", track: Int = 1) -> Song {
        Song(id: id, title: id, album: album, artist: "Artist", track: track, duration: 30,
             albumId: album, artistId: "artist")
    }

    @Test func partialCollectionsKeepOnlyPlayableTracksAndPreservePlaylistOrder() {
        let first = song("first", track: 1)
        let second = song("second", track: 2)
        let remote = song("remote", album: "remote-album")
        let lists = [Playlist(id: "partial", name: "Partial", songCount: 4, duration: 120),
                     Playlist(id: "empty", name: "Empty", songCount: 1, duration: 30)]
        let favorites = HomeFavorites(songs: [first, remote],
            albums: [AlbumID3(id: "album", name: "Album", songCount: 3, duration: 90),
                     AlbumID3(id: "remote-album", name: "Remote", songCount: 1, duration: 30)])
        let offline = OfflineBrowsingSnapshot(songs: [DisplayableSong(from: second), DisplayableSong(from: first)],
            playlists: lists, membership: ["partial": ["second", "remote", "first", "second"], "empty": ["remote"]], favorites: favorites)
        #expect(offline.playlistIDs == ["partial"])
        #expect(offline.playlistSongs["partial"]?.map(\.id) == ["second", "first", "second"])
        #expect(offline.playlists.first?.songCount == 3)
        #expect(offline.albumSongs("album").map(\.id) == ["first", "second"])
        #expect(offline.albumIDs == ["album"])
        #expect(offline.favorites.songs.map(\.id) == ["first"])
        #expect(offline.favorites.albums.map(\.id) == ["album"])
        #expect(lists.count == 2 && favorites.songs.count == 2)
    }

    @Test func emptyOfflineSnapshotHasNoSections() {
        let offline = OfflineBrowsingSnapshot(playlists: [Playlist(id: "missing", name: "Missing", songCount: 2, duration: 60)],
                                             membership: ["missing": ["remote"]])
        #expect(offline.songs.isEmpty && offline.albums.isEmpty && offline.artists.isEmpty && offline.playlists.isEmpty)
    }

    @Test func readsActualFilesAcrossManualFavoritesAndCacheWithoutChangingSavedCatalog() async throws {
        let models = try ModelContainer.minidisc(inMemory: true)
        let index = LibraryIndexStore(modelContainer: try ModelContainer.libraryIndex(inMemory: true))
        let server = MockServerService()
        let account = ServerSnapshot(from: ServerConfig(displayName: "Fixture", baseURL: "https://example.invalid", username: "fixture"))
        server.state.activeServer = account
        server.state.isOnline = false
        let id = account.id
        let root = URL.temporaryDirectory.appendingPathComponent("offline-browse-\(UUID())")
        let manualFolder = URL.documentsDirectory.appendingPathComponent("app.minidisc/downloads/\(id)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: manualFolder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: manualFolder)
        }
        let data = Data("ID3 offline fixture".utf8)
        try data.write(to: manualFolder.appendingPathComponent("manual.mp3"))
        for track in ["manual", "missing"] {
            models.mainContext.insert(DownloadedTrack(songId: track, serverId: id, albumId: "manual-album",
                filePath: "\(id)/\(track).mp3", fileSize: Int64(data.count), mimeType: "audio/mpeg", title: track,
                artist: "Artist", artistId: "artist", album: "Manual Album"))
        }
        models.mainContext.insert(DownloadedPlaylist(playlistId: "manual-list", serverId: id, name: "Manual",
            tracksCount: 2, totalTracksCount: 2, songIds: ["missing", "manual"]))
        try models.mainContext.save()
        let favorites = OfflineFavoritesStore(directory: root.appendingPathComponent("favorites"))
        let favorite = song("favorite", album: "favorite-album")
        let starred = try JSONDecoder().decode(Starred2.self, from: JSONSerialization.data(withJSONObject: ["song": [["id": "favorite", "title": "favorite", "albumId": "favorite-album", "artistId": "artist"]]]))
        _ = try await favorites.reconcile(favorites: starred, albums: [], serverID: id)
        let favoriteFile = root.appendingPathComponent("favorite.mp3")
        try data.write(to: favoriteFile)
        try await favorites.store(fileAt: favoriteFile, songID: favorite.id, serverID: id)
        let cache = AudioStreamCache(modelContainer: models)
        let cacheFile = root.appendingPathComponent("cached.mp3")
        try data.write(to: cacheFile)
        let cachedURL = try await cache.store(fileAt: cacheFile, forSongId: "cached", serverId: id, mimeType: "audio/mpeg")
        defer { try? FileManager.default.removeItem(at: cachedURL) }
        try await index.upsertTracks([song("cached"), song("remote")], serverID: id, generation: "fixture", serverOrderStart: 0)
        try await index.cachePlaylistDetail(PlaylistWithSongs(id: "cached-list", name: "Cached membership", songCount: 3,
            duration: 90, entry: [song("remote"), favorite, song("cached")]), serverID: id)
        // An explicitly cleared download must not resurrect older indexed membership.
        // Legacy downloads without saved membership still use the index as a fallback.
        for (playlistID, count) in [("cleared-list", 0), ("legacy-list", 1)] {
            models.mainContext.insert(DownloadedPlaylist(playlistId: playlistID, serverId: id,
                name: playlistID, tracksCount: 0, totalTracksCount: count, songIds: []))
            try await index.cachePlaylistDetail(PlaylistWithSongs(id: playlistID, name: playlistID,
                songCount: 1, duration: 30, entry: [song("manual")]), serverID: id)
        }
        try models.mainContext.save()
        let downloads = DownloadService(serverService: server, modelContainer: models, toastService: ToastService())
        let reader = OfflineBrowsingReader(models: models, downloads: downloads, cache: cache, favorites: favorites, index: index)
        let snapshot = try await reader.read(serverID: id)
        #expect(snapshot.songIDs == ["manual", "favorite", "cached"])
        #expect(snapshot.playlistSongs["manual-list"]?.map(\.id) == ["manual"])
        #expect(snapshot.playlistSongs["cached-list"]?.map(\.id) == ["favorite", "cached"])
        #expect(snapshot.playlistSongs["cleared-list"] == nil)
        #expect(snapshot.playlistSongs["legacy-list"]?.map(\.id) == ["manual"])
        #expect(snapshot.songs.first(where: { $0.id == "manual" })?.isDownloaded == true)
        #expect(snapshot.songs.first(where: { $0.id == "favorite" })?.isDownloaded == false)
        #expect(try await reader.read(serverID: UUID()).songs.isEmpty)
        #expect(try await index.playlist(id: "cached-list", serverID: id)?.playlist.entry?.count == 3)
        let state = OfflineBrowsingLibrary(state: server.state, reader: reader)
        await state.refresh()
        #expect(state.snapshot.songIDs == snapshot.songIDs)
        server.state.isOnline = true
        await state.refresh()
        #expect(state.snapshot.songs.isEmpty)
        #expect(try await index.songs(serverID: id, offset: 0, count: 10).count == 2)
        try FileManager.default.removeItem(at: cachedURL)
        server.state.isOnline = false
        await state.refresh()
        #expect(state.snapshot.songIDs == ["manual", "favorite"])
        server.state.activeServer = ServerSnapshot(from: ServerConfig(displayName: "Other", baseURL: "https://other.invalid", username: "fixture"))
        #expect(state.snapshot.songs.isEmpty)
    }
}
