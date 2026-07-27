import Foundation
import SwiftData
import Testing
@testable import Minidisc

@Suite("Offline library removal coordinator")
@MainActor
struct OfflineLibraryRemovalCoordinatorTests {
    private func makeSubject() throws -> (
        coordinator: OfflineLibraryRemovalCoordinator,
        container: ModelContainer,
        downloadsDirectory: URL,
        serverId: UUID
    ) {
        let container = try ModelContainer.minidisc(inMemory: true)
        let downloadsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("minidisc-offline-removal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: downloadsDirectory,
            withIntermediateDirectories: true
        )
        return (
            OfflineLibraryRemovalCoordinator(
                modelContainer: container,
                downloadsDirectory: downloadsDirectory
            ),
            container,
            downloadsDirectory,
            UUID()
        )
    }

    private func insertTrack(
        _ container: ModelContainer,
        songId: String,
        serverId: UUID,
        filePath: String,
        albumId: String? = "album"
    ) {
        container.mainContext.insert(
            DownloadedTrack(
                songId: songId,
                serverId: serverId,
                albumId: albumId,
                filePath: filePath,
                fileSize: 3,
                mimeType: "audio/mpeg",
                title: songId
            )
        )
    }

    private func writeAudioFile(
        in downloadsDirectory: URL,
        relativePath: String
    ) throws -> URL {
        let url = downloadsDirectory.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([1, 2, 3]).write(to: url)
        return url
    }

    @Test("explicit track removal commits metadata and deletes its file")
    func trackRemovalCommitsMetadataAndDeletesFile() async throws {
        let subject = try makeSubject()
        defer { try? FileManager.default.removeItem(at: subject.downloadsDirectory) }
        let relativePath = "\(subject.serverId.uuidString)/track.mp3"
        let fileURL = try writeAudioFile(
            in: subject.downloadsDirectory,
            relativePath: relativePath
        )
        insertTrack(
            subject.container,
            songId: "track",
            serverId: subject.serverId,
            filePath: relativePath
        )
        subject.container.mainContext.insert(
            DownloadedAlbum(
                albumId: "album",
                serverId: subject.serverId,
                name: "Album",
                tracksCount: 1,
                totalTracksCount: 1
            )
        )
        subject.container.mainContext.insert(
            DownloadedPlaylist(
                playlistId: "playlist",
                serverId: subject.serverId,
                name: "Playlist",
                tracksCount: 1,
                totalTracksCount: 1,
                songIds: ["track"]
            )
        )
        try subject.container.mainContext.save()

        try await subject.coordinator.remove(
            .track(songId: "track"),
            serverId: subject.serverId
        )

        let context = ModelContext(subject.container)
        #expect(try context.fetch(FetchDescriptor<DownloadedTrack>()).isEmpty)
        let album = try #require(context.fetch(FetchDescriptor<DownloadedAlbum>()).first)
        #expect(album.tracksCount == 0)
        let playlist = try #require(context.fetch(FetchDescriptor<DownloadedPlaylist>()).first)
        #expect(playlist.songIds.isEmpty)
        #expect(playlist.tracksCount == 0)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test("album removal keeps a playlist-owned track and its file")
    func albumRemovalKeepsPlaylistOwnedFile() async throws {
        let subject = try makeSubject()
        defer { try? FileManager.default.removeItem(at: subject.downloadsDirectory) }
        let sharedPath = "\(subject.serverId.uuidString)/shared.mp3"
        let albumOnlyPath = "\(subject.serverId.uuidString)/album-only.mp3"
        let sharedURL = try writeAudioFile(
            in: subject.downloadsDirectory,
            relativePath: sharedPath
        )
        let albumOnlyURL = try writeAudioFile(
            in: subject.downloadsDirectory,
            relativePath: albumOnlyPath
        )
        insertTrack(
            subject.container,
            songId: "shared",
            serverId: subject.serverId,
            filePath: sharedPath
        )
        insertTrack(
            subject.container,
            songId: "album-only",
            serverId: subject.serverId,
            filePath: albumOnlyPath
        )
        subject.container.mainContext.insert(
            DownloadedAlbum(
                albumId: "album",
                serverId: subject.serverId,
                name: "Album",
                tracksCount: 2,
                totalTracksCount: 2
            )
        )
        subject.container.mainContext.insert(
            DownloadedPlaylist(
                playlistId: "playlist",
                serverId: subject.serverId,
                name: "Playlist",
                tracksCount: 1,
                totalTracksCount: 1,
                songIds: ["shared"]
            )
        )
        try subject.container.mainContext.save()

        try await subject.coordinator.remove(
            .album(albumId: "album"),
            serverId: subject.serverId
        )

        let context = ModelContext(subject.container)
        #expect(try context.fetch(FetchDescriptor<DownloadedAlbum>()).isEmpty)
        #expect(Set(try context.fetch(FetchDescriptor<DownloadedTrack>()).map(\.songId)) == ["shared"])
        #expect(FileManager.default.fileExists(atPath: sharedURL.path))
        #expect(!FileManager.default.fileExists(atPath: albumOnlyURL.path))
    }

    @Test("a missing audio file does not block metadata removal")
    func missingFileDoesNotBlockMetadataRemoval() async throws {
        let subject = try makeSubject()
        defer { try? FileManager.default.removeItem(at: subject.downloadsDirectory) }
        insertTrack(
            subject.container,
            songId: "missing",
            serverId: subject.serverId,
            filePath: "\(subject.serverId.uuidString)/missing.mp3"
        )
        try subject.container.mainContext.save()

        try await subject.coordinator.remove(
            .track(songId: "missing"),
            serverId: subject.serverId
        )

        let context = ModelContext(subject.container)
        #expect(try context.fetch(FetchDescriptor<DownloadedTrack>()).isEmpty)
    }

    @Test("remove all clears every server and its audio files")
    func removeAllClearsEveryServerAndFile() async throws {
        let subject = try makeSubject()
        defer { try? FileManager.default.removeItem(at: subject.downloadsDirectory) }
        let otherServerId = UUID()
        let firstPath = "\(subject.serverId.uuidString)/first.mp3"
        let secondPath = "\(otherServerId.uuidString)/second.mp3"
        let firstURL = try writeAudioFile(
            in: subject.downloadsDirectory,
            relativePath: firstPath
        )
        let secondURL = try writeAudioFile(
            in: subject.downloadsDirectory,
            relativePath: secondPath
        )
        insertTrack(
            subject.container,
            songId: "first",
            serverId: subject.serverId,
            filePath: firstPath
        )
        insertTrack(
            subject.container,
            songId: "second",
            serverId: otherServerId,
            filePath: secondPath,
            albumId: nil
        )
        subject.container.mainContext.insert(
            DownloadedAlbum(
                albumId: "album",
                serverId: subject.serverId,
                name: "Album",
                tracksCount: 1,
                totalTracksCount: 1
            )
        )
        subject.container.mainContext.insert(
            DownloadedPlaylist(
                playlistId: "playlist",
                serverId: otherServerId,
                name: "Playlist",
                tracksCount: 1,
                totalTracksCount: 1,
                songIds: ["second"]
            )
        )
        try subject.container.mainContext.save()

        try await subject.coordinator.removeAll()

        let context = ModelContext(subject.container)
        #expect(try context.fetch(FetchDescriptor<DownloadedAlbum>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<DownloadedPlaylist>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<DownloadedTrack>()).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: firstURL.path))
        #expect(!FileManager.default.fileExists(atPath: secondURL.path))
    }
}
