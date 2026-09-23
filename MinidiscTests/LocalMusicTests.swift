import Foundation
import Testing
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
