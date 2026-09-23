import Testing
import Foundation
import SwiftData
import SwiftSonic
@testable import Minidisc

@MainActor
private final class PDLibraryStub: PlaylistBrowsing {
    var playlistResult: PlaylistWithSongs?
    var failure: SwiftSonicError?
    @MainActor
    func playlist(id: String) async throws -> PlaylistWithSongs {
        if let failure { throw failure }
        if let playlistResult { return playlistResult }
        throw URLError(.notConnectedToInternet)
    }
    func playlists() async throws -> [Playlist] { throw URLError(.unknown) }
}

@MainActor
private final class PDDownloadStub: DownloadServiceProtocol {
    var playlistData: LocalPlaylistData?

    let progressStream: AsyncStream<[DownloadProgress]> = AsyncStream { $0.finish() }
    func localPlaylistData(playlistId: String, serverId: UUID) async -> LocalPlaylistData? { playlistData }
    func localArtistData(artistId: String, artistName: String?, serverId: UUID) async -> LocalArtistData? { nil }
    func backfillPlaylistSongIds(playlistId: String, serverId: UUID, orderedSongIds: [String]) async {}
    func localAlbumData(albumId: String, serverId: UUID) async -> LocalAlbumData? { nil }
    func downloadedURL(forSongId songId: String, serverId: UUID) async -> URL? { nil }
    func isDownloaded(songId: String, serverId: UUID) async -> Bool { false }
    func downloadedSongIds(serverId: UUID) async -> Set<String> { [] }
    func localCoverArtURL(forId coverArtId: String) async -> URL? { nil }
    func persistCover(_ data: Data, forId coverArtId: String) async {}
    func removeCover(forId coverArtId: String) async {}
    func garbageCollectOrphanedCovers(referencedIds: Set<String>) async -> Int { 0 }
    func coverCacheStats() async -> (count: Int, bytes: Int64) { (0, 0) }
    func clearAllCovers() async {}
    func download(song: Song, serverId: UUID) async throws { throw URLError(.unknown) }
    func download(album: AlbumID3, serverId: UUID) async throws { throw URLError(.unknown) }
    func download(playlist: PlaylistWithSongs, serverId: UUID) async throws { throw URLError(.unknown) }
    func isDownloading(songId: String, serverId: UUID) async -> Bool { false }
    func isDownloadingAlbum(_ albumId: String) async -> Bool { false }
    func isDownloadingPlaylist(_ playlistId: String) async -> Bool { false }
    func cancelDownload(songId: String, serverId: UUID) async {}
    func remove(songId: String, serverId: UUID) async throws { throw URLError(.unknown) }
    func remove(albumId: String, serverId: UUID) async throws { throw URLError(.unknown) }
    func remove(playlistId: String, serverId: UUID) async throws { throw URLError(.unknown) }
    func removeAll() async throws { throw URLError(.unknown) }
}

@MainActor
private final class PDPlaylistStub: PlaylistServiceProtocol {
    var calls: [String] = []
    var failsAt: String?
    var holdRemoval = false
    var removedIndices: [[Int]] = []
    private var removal: CheckedContinuation<Void, any Error>?
    private var removalStarted: CheckedContinuation<Void, Never>?
    func waitForRemoval() async {
        if removal != nil { return }
        await withCheckedContinuation { removalStarted = $0 }
    }
    func finishRemoval(failing: Bool) {
        let pending = removal
        removal = nil
        if failing { pending?.resume(throwing: URLError(.timedOut)) }
        else { pending?.resume() }
    }
    private func record(_ operation: String) throws {
        calls.append(operation)
        if failsAt == operation { throw URLError(.timedOut) }
    }
    func listPlaylists() async throws -> [Playlist] { throw URLError(.unknown) }
    func getPlaylist(id: String) async throws -> PlaylistWithSongs { throw URLError(.unknown) }
    @discardableResult
    func createPlaylist(name: String, description: String?) async throws -> PlaylistWithSongs { throw URLError(.unknown) }
    func renamePlaylist(id: String, newName: String) async throws { try record("rename") }
    func updateDescription(id: String, description: String) async throws { try record("description:\(description)") }
    func addTracks(playlistId: String, songs: [Song]) async throws { throw URLError(.unknown) }
    func removeTracks(playlistId: String, indices: [Int]) async throws {
        removedIndices.append(indices)
        guard holdRemoval else { throw URLError(.unknown) }
        try await withCheckedThrowingContinuation { continuation in
            removal = continuation
            removalStarted?.resume()
            removalStarted = nil
        }
    }
    func reorderTracks(playlistId: String, orderedSongIds: [String]) async throws { try record("reorder") }
    func deletePlaylist(id: String, purgeDownloads: Bool) async throws { throw URLError(.unknown) }
}

@Suite("PlaylistDetailViewModel — offline local fallback")
@MainActor
struct PlaylistDetailOfflineTests {

    private func song(_ id: String) -> DisplayableSong {
        DisplayableSong(
            id: id, title: "Track \(id)", artist: "Artist", albumId: nil,
            albumName: nil, artistId: nil, genre: nil, duration: 180,
            trackNumber: nil, isDownloaded: true, coverArtId: nil, audioFormat: nil,
            replayGainTrackGain: nil, replayGainTrackPeak: nil,
            replayGainAlbumGain: nil, replayGainAlbumPeak: nil,
            replayGainBaseGain: nil, replayGainFallbackGain: nil
        )
    }

    private func makeVM(playlistData: LocalPlaylistData?, isOnline: Bool, apiPlaylist: PlaylistWithSongs? = nil, failure: SwiftSonicError? = nil) -> PlaylistDetailViewModel {
        let state = ServerState()
        state.isOnline = isOnline
        state.activeServer = ServerSnapshot(from: ServerConfig(
            displayName: "S", baseURL: "https://s.example.com", username: "u", isActive: true
        ))
        let download = PDDownloadStub()
        download.playlistData = playlistData
        let library = PDLibraryStub()
        library.playlistResult = apiPlaylist
        library.failure = failure
        return PlaylistDetailViewModel(
            playlistId: "playlist-1",
            libraryService: library,
            downloadService: download,
            playlistService: PDPlaylistStub(),
            toastService: ToastService(),
            serverState: state
        )
    }

    private var emptySuccessPlaylist: PlaylistWithSongs {
        PlaylistWithSongs(id: "playlist-1", name: "Road Trip", songCount: 0, duration: 0)
    }

    private var downloadedPlaylist: LocalPlaylistData {
        LocalPlaylistData(
            playlistId: "playlist-1", name: "Road Trip", coverArtId: nil,
            songs: [song("1"), song("2")]
        )
    }

    @Test("downloaded playlist falls back to local when the server call fails (stale isOnline)")
    func downloadedPlaylistFallsBackOnServerFailure() async {
        let vm = makeVM(playlistData: downloadedPlaylist, isOnline: true)
        await vm.load()
        #expect(vm.songs.count == 2)
        #expect(vm.error == nil)
        #expect(vm.isOffline == true)
        #expect(vm.name == "Road Trip")
    }

    @Test("transient failure with no local copy shows the error, not a false offline state")
    func transientFailureWithoutLocalCopyShowsError() async {
        let vm = makeVM(playlistData: nil, isOnline: true)
        await vm.load()
        #expect(vm.error != nil)
        #expect(vm.isOffline == false)
        #expect(vm.songs.isEmpty)
    }

    @Test("genuinely offline, downloaded playlist loads from local with no server call")
    func offlineDownloadedPlaylistLoadsLocally() async {
        let vm = makeVM(playlistData: downloadedPlaylist, isOnline: false)
        await vm.load()
        #expect(vm.songs.count == 2)
        #expect(vm.error == nil)
        #expect(vm.isOffline == true)
    }

    @Test("genuinely offline, non-downloaded playlist shows the empty state — no error")
    func offlineNonDownloadedShowsEmptyState() async {
        let vm = makeVM(playlistData: nil, isOnline: false)
        await vm.load()
        #expect(vm.songs.isEmpty)
        #expect(vm.error == nil)
        #expect(vm.isOffline == true)
    }

    @Test("empty-success playlist response with a downloaded copy loads local, not Empty")
    func emptySuccessFallsBackToLocal() async {
        let vm = makeVM(playlistData: downloadedPlaylist, isOnline: true, apiPlaylist: emptySuccessPlaylist)
        await vm.load()
        #expect(vm.songs.count == 2)
        #expect(vm.error == nil)
        #expect(vm.isOffline == true)
        #expect(vm.name == "Road Trip")
    }

    @Test("empty-success playlist with NO downloaded copy stays empty, no error")
    func emptySuccessNoLocalStaysEmpty() async {
        let vm = makeVM(playlistData: nil, isOnline: true, apiPlaylist: emptySuccessPlaylist)
        await vm.load()
        #expect(vm.songs.isEmpty)
        #expect(vm.error == nil)
    }
    @Test func removedPlaylistPreservesDownloadedCopy() async throws {
        let vm = makeVM(playlistData: downloadedPlaylist, isOnline: true, failure: try await playlistServerError())
        await vm.load()
        #expect(vm.isRemovedFromServer)
        #expect(vm.songs.map(\.id) == ["1", "2"])
        #expect(vm.playlistDetail == nil)
        #expect(vm.error == nil)
        let playable = await vm.playbackSongs(from: downloadedPlaylist.songs)
        #expect(playable.map(\.id) == ["1", "2"])
    }

    @Test func removedPlaylistClearsAnOldScreenAndDoesNotStartDeadTracks() async throws {
        let vm = makeVM(playlistData: nil, isOnline: true, failure: try await playlistServerError())
        vm.songs = downloadedPlaylist.songs
        await vm.load()
        #expect(vm.isRemovedFromServer)
        #expect(vm.songs.isEmpty)
        #expect(await vm.playbackSongs(from: downloadedPlaylist.songs).isEmpty)
    }

    @Test func proxy404DoesNotConfirmPlaylistRemoval() async {
        let vm = makeVM(playlistData: nil, isOnline: true, failure: .httpError(
            statusCode: 404, endpoint: "getPlaylist", serverHost: "s.example.com"
        ))
        vm.songs = downloadedPlaylist.songs
        await vm.load()
        #expect(!vm.isRemovedFromServer)
        #expect(vm.songs.count == 2)
        #expect(vm.error != nil)
    }

}

@Suite @MainActor
struct PlaylistEditCommitterTests {
    @Test func metadataFollowsReplacementIncludingEmptyDescription() async throws {
        let service = PDPlaylistStub()
        try await PlaylistEditCommitter.commit(.init(name: "New", orderedSongIDs: ["2", "1"], description: ""), playlistID: "p", service: service)
        #expect(service.calls == ["reorder", "rename", "description:"])
    }

    @Test func failureStopsTheCommitAndAllowsAnIdempotentRetry() async {
        let service = PDPlaylistStub()
        let toast = ToastService()
        service.failsAt = "rename"
        let edits = PlaylistEdits(name: "New", orderedSongIDs: ["2", "1"], description: "Notes")
        let first = await toast.perform { try await PlaylistEditCommitter.commit(edits, playlistID: "p", service: service) }
        #expect(!first)
        #expect(service.calls == ["reorder", "rename"])
        #expect(toast.current?.style == .error)
        service.failsAt = nil
        let retry = await toast.perform { try await PlaylistEditCommitter.commit(edits, playlistID: "p", service: service) }
        #expect(retry)
        #expect(service.calls == ["reorder", "rename", "reorder", "rename", "description:Notes"])
    }

    @Test func cancellationDoesNotShowAnError() async {
        let toast = ToastService()
        let saved = await toast.perform { throw CancellationError() }
        #expect(!saved)
        #expect(toast.current == nil)
    }
}

@Suite @MainActor
struct PlaylistMutationSafetyTests {
    @Test func pendingRemovalRejectsAnotherMutationAndFailureKeepsTheOriginalList() async {
        let service = PDPlaylistStub()
        service.holdRemoval = true
        let vm = model(service)
        vm.songs = songs(["a", "b", "c"])
        let first = Task { await vm.removeTrack(at: 2) }
        await service.waitForRemoval()
        #expect(vm.isMutatingTracks)
        await vm.removeTrack(at: 0)
        await vm.moveTracks(from: IndexSet(integer: 0), to: 3)
        #expect(service.removedIndices == [[2]])
        #expect(service.calls.isEmpty)
        service.finishRemoval(failing: true)
        await first.value
        #expect(vm.songs.map(\.id) == ["a", "b", "c"])
        #expect(!vm.isMutatingTracks)
    }

    @Test func failedRemovalDoesNotOverwriteARefresh() async {
        let service = PDPlaylistStub()
        service.holdRemoval = true
        let vm = model(service)
        vm.songs = songs(["a", "b", "c"])
        let task = Task { await vm.removeTrack(at: 2) }
        await service.waitForRemoval()
        vm.songs = songs(["fresh"])
        service.finishRemoval(failing: true)
        await task.value
        #expect(vm.songs.map(\.id) == ["fresh"])
    }

    @Test func batchRemovalPreservesTheOtherDuplicate() async {
        let service = PDPlaylistStub()
        service.holdRemoval = true
        let vm = model(service)
        vm.songs = songs(["a", "b", "a", "c"])
        let task = Task { await vm.removeTracks(at: IndexSet([1, 2]), expectedSongIDs: ["a", "b", "a", "c"]) }
        await service.waitForRemoval()
        service.finishRemoval(failing: false)
        await task.value
        #expect(service.removedIndices == [[1, 2]])
        #expect(vm.songs.map(\.id) == ["a", "c"])
        await vm.removeTracks(at: IndexSet(integer: 1), expectedSongIDs: ["stale", "snapshot"])
        #expect(service.removedIndices.count == 1)
    }

    private func songs(_ ids: [String]) -> [DisplayableSong] {
        ids.map { DisplayableSong(from: Song(id: $0, title: $0)) }
    }

    private func model(_ service: PDPlaylistStub) -> PlaylistDetailViewModel {
        let state = ServerState()
        state.activeServer = ServerSnapshot(from: ServerConfig(displayName: "Test", baseURL: "https://example.invalid", username: "test"))
        return PlaylistDetailViewModel(playlistId: "p", libraryService: PDLibraryStub(),
            downloadService: PDDownloadStub(), playlistService: service, toastService: ToastService(), serverState: state)
    }
}

@Suite @MainActor
struct PlaylistPersistenceIntegrationTests {
    @Test func mutationsReconcileDownloadedMembershipWithoutWarmingAServiceCache() async throws {
        let models = try ModelContainer.minidisc(inMemory: true)
        let index = LibraryIndexStore(modelContainer: try ModelContainer.libraryIndex(inMemory: true))
        let server = ServerService(state: ServerState(), keychain: MockKeychain(), modelContainer: models, audioStreamCache: MockAudioStreamCache())
        try await server.addServer(displayName: "Test", baseURL: "https://example.invalid", username: "u", password: "p", customHeaders: [:])
        let serverID = try await server.activeConnection().version.serverID
        let otherID = UUID()
        for id in [serverID, otherID] {
            models.mainContext.insert(DownloadedPlaylist(playlistId: "p", serverId: id, name: "Original", tracksCount: 3, totalTracksCount: 3, songIds: ["a", "b", "a"]))
            for song in ["a", "b"] {
                models.mainContext.insert(DownloadedTrack(songId: song, serverId: id, filePath: "unused", fileSize: 0, mimeType: "audio/mpeg", title: song))
            }
        }
        try models.mainContext.save()
        let transport = PlaylistMutationTransport()
        let source = SwiftSonicLibrarySource(serverService: server)
        let catalog = LibraryCatalog(source: source, store: index, synchronizer: LibraryIndexSynchronizer(source: source, store: index))
        let service = PlaylistService(serverService: server, modelContainer: models, downloadService: PDDownloadStub(), libraryCatalog: catalog,
            clientFactory: { connection in
                SwiftSonicClient(configuration: ServerConfiguration(serverURL: connection.baseURL, username: "u", password: "p"), transport: transport, retryPolicy: .none)
            })
        func saved(_ id: UUID) throws -> DownloadedPlaylist {
            try #require(ModelContext(models).fetch(FetchDescriptor<DownloadedPlaylist>(predicate: #Predicate { $0.serverId == id })).first)
        }
        await transport.setSongIDs(["a"])
        await service.retryMissingPlaylistDownloads()
        #expect(await transport.playlistReads == 1)
        #expect(try saved(serverID).songIds == ["a", "b", "a"])
        #expect(try saved(otherID).songIds == ["a", "b", "a"])
        await transport.setSongIDs(["a", "b", "a"])
        try await service.removeTracks(playlistId: "p", indices: [2])
        #expect(try saved(serverID).songIds == ["a", "b"])
        #expect(try saved(otherID).songIds == ["a", "b", "a"])
        try await service.reorderTracks(playlistId: "p", orderedSongIds: ["b", "a", "a"])
        #expect(try saved(serverID).songIds == ["b", "a", "a"])
        #expect(try saved(serverID).tracksCount == 3)
        try await service.renamePlaylist(id: "p", newName: "Updated")
        try await service.updateDescription(id: "p", description: "Notes")
        #expect(try saved(serverID).name == "Updated")
        #expect(try saved(serverID).comment == "Notes")
        await transport.setFailure(true)
        await #expect(throws: (any Error).self) { try await service.removeTracks(playlistId: "p", indices: [0]) }
        #expect(try saved(serverID).songIds == ["b", "a", "a"])
        await transport.setFailure(false)
        try await service.reorderTracks(playlistId: "p", orderedSongIds: [])
        #expect(try saved(serverID).songIds.isEmpty)
        #expect(try saved(serverID).totalTracksCount == 0)
        let previousReads = await transport.playlistReads
        await service.retryMissingPlaylistDownloads()
        #expect(await transport.playlistReads == previousReads)
        #expect(try ModelContext(models).fetchCount(FetchDescriptor<DownloadedTrack>()) == 4)
        let detail = try await index.playlist(id: "p", serverID: serverID)
        #expect(detail?.playlist.entry?.isEmpty == true)
    }
}

private actor PlaylistMutationTransport: HTTPTransport {
    private var ids = ["a", "b", "a"]
    private var name = "Original"
    private var comment = ""
    private var fail = false
    private(set) var playlistReads = 0
    func setSongIDs(_ value: [String]) { ids = value }
    func setFailure(_ value: Bool) { fail = value }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        let query = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            + (request.httpBody.flatMap { String(data: $0, encoding: .utf8) }.flatMap { URLComponents(string: "?" + $0)?.queryItems } ?? [])
        let endpoint = url.deletingPathExtension().lastPathComponent
        if endpoint == "getPlaylist" { playlistReads += 1 }
        if endpoint != "getPlaylist", fail { throw URLError(.timedOut) }
        if endpoint == "createPlaylist" { ids = query.filter { $0.name == "songId" }.compactMap(\.value) }
        if endpoint == "updatePlaylist" {
            let removed = Set(query.filter { $0.name == "songIndexToRemove" }.compactMap { $0.value.flatMap(Int.init) })
            ids = ids.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
            ids += query.filter { $0.name == "songIdToAdd" }.compactMap(\.value)
            if let value = query.first(where: { $0.name == "name" })?.value { name = value }
            if let value = query.first(where: { $0.name == "comment" })?.value { comment = value }
        }
        let playlist: [String: Any] = ["id": "p", "name": name, "comment": comment,
            "songCount": ids.count, "duration": 0, "entry": ids.map { ["id": $0, "title": $0] }]
        let data = try JSONSerialization.data(withJSONObject: ["subsonic-response": ["status": "ok", "version": "1.16.1", "playlist": playlist]])
        return (data, try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
    }
}
