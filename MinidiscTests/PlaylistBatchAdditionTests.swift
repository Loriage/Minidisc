import Foundation
import SwiftSonic
import Testing
@testable import Minidisc

@Suite("Batch playlist addition")
@MainActor
struct PlaylistBatchAdditionTests {
    @Test("The existing playlist creation flow reuses its created destination on retry")
    func creationReusesDestination() async throws {
        let service = BatchPlaylistStub()
        let model = CreatePlaylistViewModel(playlistService: service, toastService: ToastService())
        model.name = "Saved queue"
        let first = await model.create()
        let second = await model.create()
        #expect(first?.id == second?.id)
        #expect(service.createCalls == 1)
    }

    @Test("A lost response is reconciled without repeating accepted songs")
    func retriesLostResponse() async throws {
        let songs = try makeSongs(["a", "b", "b"])
        let service = BatchPlaylistStub()
        service.setFailure(.afterAppend)
        let (vm, defaults, key) = model(songs, service)
        defer { defaults.removePersistentDomain(forName: key) }
        #expect(await vm.checkAndAdd(to: destination) == .failed)
        #expect(vm.error != nil)
        #expect(vm.recentIDs.isEmpty)
        #expect(await vm.checkAndAdd(to: destination) == .added)
        #expect(service.ids == ["a", "b", "b"])
        #expect(service.appendCalls == 1)
        #expect(vm.recentIDs == [destination.id])
    }

    @Test("A partial append retries only missing occurrences in requested order")
    func retriesPartialAppend() async throws {
        let service = BatchPlaylistStub()
        service.setFailure(.partialAppend)
        let (vm, defaults, key) = model(try makeSongs(["a", "b", "b", "c"]), service)
        defer { defaults.removePersistentDomain(forName: key) }
        #expect(await vm.checkAndAdd(to: destination) == .failed)
        #expect(await vm.checkAndAdd(to: destination) == .added)
        #expect(service.ids == ["a", "b", "b", "c"])
        #expect(service.appendBatches == [["a", "b", "b", "c"], ["b", "b", "c"]])
    }

    @Test("Duplicate choices preserve existing tracks and skip only when requested")
    func duplicateDecision() async throws {
        let service = BatchPlaylistStub()
        service.setSongs(try makeSongs(["a"]).map { $0.asSong() })
        let (vm, defaults, key) = model(try makeSongs(["a", "b"]), service)
        defer { defaults.removePersistentDomain(forName: key) }
        #expect(await vm.checkAndAdd(to: destination) == .duplicate)
        #expect(service.appendCalls == 0)
        #expect(await vm.forceAdd(to: destination, skippingDuplicates: true))
        #expect(service.ids == ["a", "b"])
    }

    @Test("A failed duplicate lookup does not blindly mutate the playlist")
    func failedLookupDoesNotAppend() async throws {
        let service = BatchPlaylistStub()
        service.setFailure(.lookup)
        let (vm, defaults, key) = model(try makeSongs(["a"]), service)
        defer { defaults.removePersistentDomain(forName: key) }
        #expect(await vm.checkAndAdd(to: destination) == .failed)
        #expect(service.appendCalls == 0)
        #expect(vm.songs.map(\.id) == ["a"])
    }

    @Test("Retry finishes the same newly-created playlist and keeps the draft name")
    func keepsCreatedDestination() async throws {
        let service = BatchPlaylistStub()
        service.setFailure(.beforeAppend)
        let (vm, defaults, key) = model(try makeSongs(["a", "b"]), service)
        defer { defaults.removePersistentDomain(forName: key) }
        vm.newPlaylistName = "My queue"
        #expect(!(await vm.createAndAdd()))
        #expect(vm.createdPlaylist?.id == destination.id)
        #expect(vm.newPlaylistName == "My queue")
        #expect(await vm.createAndAdd())
        #expect(service.createCalls == 1)
        #expect(service.ids == ["a", "b"])
    }

    @Test("Recent destinations are server-scoped, filtered, and never duplicated")
    func recentDestinations() async throws {
        let service = BatchPlaylistStub()
        let (vm, defaults, key) = model(try makeSongs(["a"]), service)
        defer { defaults.removePersistentDomain(forName: key) }
        #expect(await vm.checkAndAdd(to: destination) == .added)
        await vm.load()
        #expect(vm.destinations(query: "ete", recent: true).map(\.id) == [destination.id])
        #expect(vm.destinations(query: "", recent: false).isEmpty)
        #expect(vm.destinations(query: "missing", recent: true).isEmpty)
        #expect(RecentPlaylistDestinations(serverID: "other", defaults: defaults).ids.isEmpty)
    }

    @Test("Batch presentation preserves queue order and intentional duplicates")
    func batchPresentation() throws {
        let addition = PlaylistAddition()
        addition.present(songs: try makeSongs(["a", "b", "a"]), createsPlaylist: true)
        #expect(addition.request?.songs.map(\.id) == ["a", "b", "a"])
        #expect(addition.request?.createsPlaylist == true)
        addition.dismiss()
        #expect(addition.request == nil)
    }

    private var destination: Playlist { Playlist(id: "p", name: "Été", songCount: 0, duration: 0) }

    private func model(_ songs: [DisplayableSong], _ service: BatchPlaylistStub) -> (AddToPlaylistViewModel, UserDefaults, String) {
        let key = "BatchPlaylistTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: key)!
        let vm = AddToPlaylistViewModel(songs: songs, playlistService: service, toastService: ToastService(),
                                       recents: RecentPlaylistDestinations(serverID: "server", defaults: defaults))
        return (vm, defaults, key)
    }

    private func makeSongs(_ ids: [String]) throws -> [DisplayableSong] {
        try ids.map {
            let data = try JSONSerialization.data(withJSONObject: ["id": $0, "title": $0, "isDir": false])
            return DisplayableSong(from: try JSONDecoder().decode(Song.self, from: data))
        }
    }
}

@MainActor
private final class BatchPlaylistStub: PlaylistServiceProtocol {
    enum Failure { case beforeAppend, afterAppend, partialAppend, lookup }
    var failure: Failure?
    var songs: [Song] = []
    private(set) var appendBatches: [[String]] = []
    private(set) var createCalls = 0
    var ids: [String] { songs.map(\.id) }
    var appendCalls: Int { appendBatches.count }
    func setFailure(_ value: Failure) { failure = value }
    func setSongs(_ value: [Song]) { songs = value }
    func listPlaylists() async throws -> [Playlist] { [Playlist(id: "p", name: "Été", songCount: songs.count, duration: 0)] }
    func getPlaylist(id: String) async throws -> PlaylistWithSongs {
        if failure == .lookup { failure = nil; throw URLError(.timedOut) }
        return PlaylistWithSongs(id: id, name: "Été", songCount: songs.count, duration: 0, entry: songs)
    }
    func createPlaylist(name: String, description: String?) async throws -> PlaylistWithSongs {
        createCalls += 1
        return PlaylistWithSongs(id: "p", name: name, songCount: 0, duration: 0, entry: [])
    }
    func addTracks(playlistId: String, songs added: [Song]) async throws {
        let mode = failure
        failure = nil
        appendBatches.append(added.map(\.id))
        if mode == .beforeAppend { throw URLError(.timedOut) }
        songs += mode == .partialAppend ? Array(added.prefix(1)) : added
        if mode == .afterAppend || mode == .partialAppend { throw URLError(.timedOut) }
    }
    func renamePlaylist(id: String, newName: String) async throws {}
    func updateDescription(id: String, description: String) async throws {}
    func removeTracks(playlistId: String, indices: [Int]) async throws {}
    func reorderTracks(playlistId: String, orderedSongIds: [String]) async throws {}
    func deletePlaylist(id: String, purgeDownloads: Bool) async throws {}
}
