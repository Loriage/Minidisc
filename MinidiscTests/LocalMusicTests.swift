import Foundation
import Testing
import SwiftData
import SwiftSonic
@testable import Minidisc

nonisolated enum LocalMusicFixture {
    static func wav(at url: URL) throws {
        let samples = Data(repeating: 0, count: 16_000)
        var data = Data("RIFF".utf8)
        func word(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        func short(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        word(UInt32(samples.count + 36)); data.append(Data("WAVEfmt ".utf8)); word(16)
        short(1); short(1); word(8_000); word(16_000); short(2); short(16)
        data.append(Data("data".utf8)); word(UInt32(samples.count)); data.append(samples)
        try data.write(to: url)
    }
}

@Suite struct LocalMusicTests {
    @Test @MainActor func sharedSearchKeepsBothSourcesAndRanksThemTogether() throws {
        let local = taggedTrack(title: "Été", artist: "Adèle", album: "Été", available: true)
        let unavailable = taggedTrack(title: "Été ailleurs", artist: "Adèle", album: "Été", available: false)
        let catalog = LocalMusicCatalog(tracks: [local, unavailable])
        let serverSong = DisplayableSong(from: Song(id: "server-song", title: "Été au loin"))
        let serverAlbum = AlbumID3(id: "server-album", name: "Été", songCount: 2, duration: 120)
        let matches = LibrarySearchRanking.mergingLocal(catalog,
            into: [.song(serverSong), .album(serverAlbum)], query: "ete")
        #expect(matches.contains { $0.id == "song:\(local.id)" })
        #expect(matches.contains { $0.id == "song:server-song" })
        #expect(matches.filter { $0.scope == .albums }.count == 2)
        #expect(LibrarySearchRanking.score(try #require(matches.first), query: "ete") == 1_000)
        let playable = catalog.playable([serverSong, unavailable.song, local.song])
        #expect(playable.map(\.id) == [serverSong.id, local.id])
        #expect(playable.last?.localFile == local.song.localFile)
        #expect(LibrarySearchRanking.mergingLocal(catalog, into: [], query: " \n").isEmpty)
        #expect(LibrarySearchRanking.mergingLocal(catalog, into: [], query: "missing").isEmpty)
        #expect(LibrarySearchRanking.mergingLocal(catalog, into: [], query: "adele").contains { $0.id == "song:\(unavailable.id)" })
    }

    @Test func collectionIdentityIsStableAndDoesNotMergeDifferentArtists() {
        let first = taggedTrack(title: "One", artist: "A", album: "Album", available: true)
        let second = taggedTrack(title: "Two", artist: "B", album: "Album", available: true)
        let catalog = LocalMusicCatalog(tracks: [first, second])
        #expect(catalog.albums.count == 2)
        #expect(Set(catalog.albums.map(\.id)) == Set(LocalMusicCatalog(tracks: [second, first]).albums.map(\.id)))
        #expect(catalog.albums.allSatisfy { LocalMusicCatalog.isCollectionID($0.id) })
        #expect(LocalMusicCatalog.collectionID(.albums, key: ["a:b", "c"]) != LocalMusicCatalog.collectionID(.albums, key: ["a", "b:c"]))
    }

    @Test @MainActor func discoverShuffleUsesLocalFilesWithoutAServerEvenWhenNetworkIsOnline() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Music")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try LocalMusicFixture.wav(at: folder.appendingPathComponent("One.wav"))
        try LocalMusicFixture.wav(at: folder.appendingPathComponent("Two.wav"))
        let store = LocalMusicStore(directory: root.appendingPathComponent("Index"))
        try await store.add([folder])
        let snapshot = try await store.refresh()
        let server = MockServerService()
        #expect(server.state.activeServer == nil)
        server.state.isOnline = true
        let models = try ModelContainer.minidisc(inMemory: true)
        let index = LibraryIndexStore(modelContainer: try ModelContainer.libraryIndex(inMemory: true))
        let source = SwiftSonicLibrarySource(serverService: server)
        let catalog = LibraryCatalog(source: source, store: index,
            synchronizer: LibraryIndexSynchronizer(source: source, store: index))
        let library = LibraryService(serverService: server, modelContainer: models,
            downloadService: DownloadService(serverService: server, modelContainer: models, toastService: ToastService()),
            statsService: StatsService(modelContainer: models), catalog: catalog, indexStore: index, localMusicStore: store)
        let queue = try await library.smartShuffleQueue(targetSize: 50)
        #expect(Set(queue.map(\.id)) == Set(snapshot.tracks.map(\.id)))
        #expect(queue.allSatisfy { $0.isLocalFile })
        #expect(try await library.smartShuffleQueue(targetSize: 1).count == 1)
    }

    private func taggedTrack(title: String, artist: String, album: String, available: Bool) -> LocalMusicTrack {
        let reference = LocalFileReference(folderID: UUID(), relativePath: "Track.wav")
        let song = DisplayableSong(id: reference.id, title: title, artist: artist, albumId: nil,
                                   albumName: album, artistId: nil, genre: nil, duration: 60,
                                   trackNumber: nil, isDownloaded: false, coverArtId: nil, audioFormat: "WAV",
                                   replayGainTrackGain: nil, replayGainTrackPeak: nil, replayGainAlbumGain: nil,
                                   replayGainAlbumPeak: nil, replayGainBaseGain: nil, replayGainFallbackGain: nil,
                                   localFile: reference)
        return LocalMusicTrack(song: song, isAvailable: available)
    }

    @Test func localPlaybackFiltersUnavailableTracksAndPreservesExplicitOrder() throws {
        var first = LocalMusicStore.placeholder(LocalFileReference(folderID: UUID(), relativePath: "First.wav"))
        first.isAvailable = true
        let unavailable = LocalMusicStore.placeholder(LocalFileReference(folderID: UUID(), relativePath: "Missing.wav"))
        var last = LocalMusicStore.placeholder(LocalFileReference(folderID: UUID(), relativePath: "Last.wav"))
        last.isAvailable = true
        let tracks = [first, unavailable, last]
        let queue = try LocalMusicTrack.playbackQueue(tracks, order: .shuffled)
        #expect(queue.tracks.map(\.id) == [first.id, last.id])
        #expect(queue.order == .shuffled)
        #expect(try LocalMusicTrack.playbackQueue(tracks, startingAt: last.id).startIndex == 1)
        #expect(throws: LocalMusicError.unavailable) { try LocalMusicTrack.playbackQueue(tracks, startingAt: unavailable.id) }
        #expect(throws: LocalMusicError.unavailable) { try LocalMusicTrack.playbackQueue([unavailable]) }
    }

    @Test func playerDestinationsUseLocalCollectionIdentity() {
        var track = taggedTrack(title: "Track", artist: "Artist", album: "Album", available: true).song
        #expect(LocalMusicDestination(track: track, category: .albums)?.key == ["Album", "Artist"])
        #expect(LocalMusicDestination(track: track, category: .artists)?.key == ["Artist"])
        #expect(LocalMusicDestination(track: nil, category: .albums) == nil)
        track.localFile = nil
        #expect(LocalMusicDestination(track: track, category: .albums) == nil)
    }

    @Test @MainActor func successfulRetryClearsFolderErrorAndUpdatesLibrary() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Music")
        let library = LocalMusicLibrary(store: LocalMusicStore(directory: root.appendingPathComponent("Index")))
        await library.add([folder])
        #expect(library.errorMessage != nil)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try LocalMusicFixture.wav(at: folder.appendingPathComponent("Track.wav"))
        await library.add([folder])
        #expect(library.errorMessage == nil)
        #expect(library.snapshot.tracks.count == 1)
        #expect(library.catalog.songs.count == 1)
        #expect(library.catalog.albums.count == 1)
        #expect(!library.isRefreshing)
        let savedFolder = try #require(library.snapshot.folders.first)
        await library.remove(savedFolder)
        #expect(library.catalog.songs.isEmpty)
        #expect(library.catalog.albums.isEmpty)
    }

    @Test func cloudPlaceholdersAreRejectedBeforeAnyContentRead() {
        #expect(!LocalMusicStore.isDownloaded(isUbiquitous: true, status: .notDownloaded, allocatedSize: 4096))
        #expect(!LocalMusicStore.isDownloaded(isUbiquitous: true, status: nil, allocatedSize: 4096))
        #expect(LocalMusicStore.isDownloaded(isUbiquitous: true, status: .downloaded, allocatedSize: 4096))
        #expect(LocalMusicStore.isDownloaded(isUbiquitous: true, status: .current, allocatedSize: 4096))
        #expect(!LocalMusicStore.isDownloaded(isUbiquitous: false, status: nil, allocatedSize: 0))
        #expect(!LocalMusicStore.isDownloaded(isUbiquitous: false, status: nil, allocatedSize: nil))
        #expect(LocalMusicStore.isDownloaded(isUbiquitous: false, status: nil, allocatedSize: 4096))
    }

    @Test func folderReferenceSurvivesRelaunchAndRemovalNeverDeletesAudio() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Music/Nested")
        let index = root.appendingPathComponent("Index")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let audio = folder.appendingPathComponent("Test.wav")
        try LocalMusicFixture.wav(at: audio)
        let original = try Data(contentsOf: audio)
        let store = LocalMusicStore(directory: index)
        try await store.add([folder.deletingLastPathComponent()])
        let snapshot = try await store.refresh()
        #expect(snapshot.tracks.count == 1)
        let track = try #require(snapshot.tracks.first)
        #expect(track.song.duration > 0)
        #expect(track.isAvailable)
        #expect(!track.song.isDownloaded)
        let reference = try #require(track.song.localFile)
        #expect(reference.relativePath == "Nested/Test.wav")
        let relaunched = LocalMusicStore(directory: index)
        let access = try await relaunched.access(reference)
        #expect(access.url.standardizedFileURL == audio.standardizedFileURL)
        try await relaunched.remove(reference.folderID)
        #expect(await relaunched.current().tracks.isEmpty)
        #expect(try Data(contentsOf: audio) == original)
        await #expect(throws: LocalMusicError.self) { try await relaunched.access(reference) }
    }

    @Test func rescansFindNewFilesDeduplicateOverlappingFoldersAndRemoveMissingTracks() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Music/Album")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let first = folder.appendingPathComponent("First.wav")
        try LocalMusicFixture.wav(at: first)
        let store = LocalMusicStore(directory: root.appendingPathComponent("Index"))
        try await store.add([folder.deletingLastPathComponent(), folder, folder])
        let initial = try await store.refresh()
        #expect(initial.folders.count == 2)
        #expect(initial.tracks.count == 1)
        let reference = try #require(initial.tracks.first?.song.localFile)
        let second = folder.appendingPathComponent("Second.wav")
        try LocalMusicFixture.wav(at: second)
        #expect(try await store.refresh().tracks.count == 2)
        try FileManager.default.removeItem(at: first)
        await #expect(throws: (any Error).self) { try await store.access(reference) }
        #expect(try await store.refresh().tracks.map(\.song.title) == ["Second"])
    }

    @Test func additionDateSurvivesMetadataRefreshAndIndexRelaunch() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Music")
        let index = root.appendingPathComponent("Index")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let audio = folder.appendingPathComponent("First.wav")
        try LocalMusicFixture.wav(at: audio)
        let store = LocalMusicStore(directory: index)
        try await store.add([folder])
        let initial = try await store.refresh()
        let addedAt = try #require(initial.tracks.first?.addedAt)

        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: audio.path)
        let refreshed = try await store.refresh()
        #expect(refreshed.tracks.first?.addedAt == addedAt)
        let relaunched = LocalMusicStore(directory: index)
        #expect(await relaunched.current().tracks.first?.addedAt == addedAt)
        try LocalMusicFixture.wav(at: folder.appendingPathComponent("Second.wav"))
        let updated = try await relaunched.refresh()
        #expect(updated.tracks.first(where: { $0.song.title == "First" })?.addedAt == addedAt)
        #expect(try #require(updated.tracks.first(where: { $0.song.title == "Second" })?.addedAt) >= addedAt)

        let track = try #require(initial.tracks.first)
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(track)) as? [String: Any])
        legacy.removeValue(forKey: "addedAt")
        let decoded = try JSONDecoder().decode(LocalMusicTrack.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.addedAt == nil)
        #expect(decoded.song == track.song)
    }

    @Test func aMissingFolderKeepsItsIndexButMarksSongsUnavailable() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Music")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try LocalMusicFixture.wav(at: folder.appendingPathComponent("Track.wav"))
        let store = LocalMusicStore(directory: root.appendingPathComponent("Index"))
        try await store.add([folder])
        _ = try await store.refresh()
        try FileManager.default.removeItem(at: folder)
        let result = try await store.refresh()
        #expect(result.folders.first?.isAccessible == false)
        #expect(result.tracks.count == 1)
        #expect(result.tracks.first?.isAvailable == false)
    }

    @Test func referencesCannotEscapeTheSelectedFolder() throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: URL(fileURLWithPath: "/"))
        for path in ["../outside.mp3", "/outside.mp3", "escape/tmp/outside.mp3"] {
            #expect(throws: LocalMusicError.self) { try LocalFileReference(folderID: UUID(), relativePath: path).url(in: root) }
        }
    }

    @Test func oldQueuePayloadsStillDecodeWithoutALocalReference() throws {
        let song = LocalMusicStore.placeholder(LocalFileReference(folderID: UUID(), relativePath: "Track.wav")).song
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(song)) as? [String: Any])
        object.removeValue(forKey: "localFile")
        let restored = try JSONDecoder().decode(DisplayableSong.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(restored.localFile == nil)
        #expect(try JSONDecoder().decode(DisplayableSong.self, from: JSONEncoder().encode(song)).localFile == song.localFile)
    }
}
