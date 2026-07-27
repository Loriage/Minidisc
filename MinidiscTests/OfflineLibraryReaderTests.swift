// Minidisc — Music client for Subsonic/OpenSubsonic servers
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftData
import Testing
@testable import Minidisc

@Suite("Offline library reader")
@MainActor
struct OfflineLibraryReaderTests {
    private struct Subject {
        let reader: OfflineLibraryReader
        let container: ModelContainer
        let downloadsDirectory: URL
        let serverId: UUID
    }

    private func makeSubject() throws -> Subject {
        let container = try ModelContainer.minidisc(inMemory: true)
        let downloadsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OfflineLibraryReaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: downloadsDirectory,
            withIntermediateDirectories: true
        )
        return Subject(
            reader: OfflineLibraryReader(
                modelContainer: container,
                downloadsDirectory: downloadsDirectory
            ),
            container: container,
            downloadsDirectory: downloadsDirectory,
            serverId: UUID()
        )
    }

    @discardableResult
    private func insertTrack(
        _ subject: Subject,
        songId: String,
        serverId: UUID? = nil,
        fileSize: Int64,
        bytes: [UInt8]
    ) throws -> URL {
        let serverId = serverId ?? subject.serverId
        let relativePath = "\(serverId.uuidString)/\(songId).mp3"
        let fileURL = subject.downloadsDirectory.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(bytes).write(to: fileURL)
        subject.container.mainContext.insert(
            DownloadedTrack(
                songId: songId,
                serverId: serverId,
                filePath: relativePath,
                fileSize: fileSize,
                mimeType: "audio/mpeg",
                title: songId
            )
        )
        try subject.container.mainContext.save()
        return fileURL
    }

    @Test("returns the local URL when the recorded size matches")
    func returnsValidDownloadedURL() async throws {
        let subject = try makeSubject()
        defer { try? FileManager.default.removeItem(at: subject.downloadsDirectory) }
        let expectedURL = try insertTrack(
            subject,
            songId: "valid",
            fileSize: 3,
            bytes: [1, 2, 3]
        )

        let url = await subject.reader.downloadedURL(
            forSongId: "valid",
            serverId: subject.serverId
        )

        #expect(url == expectedURL)
    }

    @Test("rejects a file whose size differs from its record")
    func rejectsMismatchedDownloadedURL() async throws {
        let subject = try makeSubject()
        defer { try? FileManager.default.removeItem(at: subject.downloadsDirectory) }
        try insertTrack(
            subject,
            songId: "truncated",
            fileSize: 10,
            bytes: [1, 2]
        )

        let url = await subject.reader.downloadedURL(
            forSongId: "truncated",
            serverId: subject.serverId
        )

        #expect(url == nil)
    }

    @Test("downloaded IDs accept legacy sizes and remain server scoped")
    func downloadedIDsAreValidAndServerScoped() async throws {
        let subject = try makeSubject()
        defer { try? FileManager.default.removeItem(at: subject.downloadsDirectory) }
        let otherServerId = UUID()
        try insertTrack(subject, songId: "current", fileSize: 1, bytes: [1])
        try insertTrack(subject, songId: "legacy", fileSize: 0, bytes: [2])
        try insertTrack(
            subject,
            songId: "other-server",
            serverId: otherServerId,
            fileSize: 1,
            bytes: [3]
        )

        let ids = await subject.reader.downloadedSongIds(serverId: subject.serverId)

        #expect(ids == ["current", "legacy"])
    }
}
