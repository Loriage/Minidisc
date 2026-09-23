import Foundation
import SwiftSonic

actor OfflineFavoritesStore {
    nonisolated struct Snapshot: Codable, Sendable {
        var favorites: Starred2?
        var albums: [String: AlbumID3] = [:]
        var files: [String: FileEntry] = [:]

        var songs: [Song] {
            var seen = Set<String>()
            return ((favorites?.song ?? []) + albums.values.flatMap { $0.song ?? [] })
                .filter { seen.insert($0.id).inserted }
        }
    }

    nonisolated struct FileEntry: Codable, Sendable {
        let filename: String
        let size: Int64
    }

    nonisolated struct Usage: Sendable {
        var count = 0
        var bytes: Int64 = 0
    }

    private let directory: URL
    private var snapshots: [UUID: Snapshot] = [:]

    init(directory: URL = URL.applicationSupportDirectory.appendingPathComponent("minidisc-offline-favorites")) {
        self.directory = directory
    }

    func snapshot(serverID: UUID) throws -> Snapshot {
        if let value = snapshots[serverID] { return value }
        let url = folder(serverID).appendingPathComponent("catalog.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return Snapshot() }
        let value = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: url))
        snapshots[serverID] = value
        return value
    }

    func saveFavorites(_ favorites: Starred2, serverID: UUID) throws {
        var value = try snapshot(serverID: serverID)
        value.favorites = favorites
        try save(value, serverID: serverID)
    }

    func reconcile(favorites: Starred2, albums: [AlbumID3], serverID: UUID) throws -> [Song] {
        try Task.checkCancellation()
        var value = try snapshot(serverID: serverID)
        value.favorites = favorites
        value.albums = Dictionary(albums.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let desired = Set(value.songs.map(\.id))
        let removed = value.files.filter { !desired.contains($0.key) }
        value.files = value.files.filter { desired.contains($0.key) }
        try save(value, serverID: serverID)
        for entry in removed.values { try? FileManager.default.removeItem(at: fileURL(entry, serverID: serverID)) }
        return value.songs
    }

    func localURL(songID: String, serverID: UUID) -> URL? {
        guard let value = try? snapshot(serverID: serverID), let entry = value.files[songID],
              entry.filename == URL(fileURLWithPath: entry.filename).lastPathComponent else { return nil }
        let url = fileURL(entry, serverID: serverID)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return size > 0 && Int64(size) == entry.size ? url : nil
    }

    func store(fileAt source: URL, songID: String, serverID: UUID) throws {
        try Task.checkCancellation()
        var value = try snapshot(serverID: serverID)
        guard value.songs.contains(where: { $0.id == songID }) else { throw CancellationError() }
        let ext = AudioContainer.sniff(atPath: source.path)?.rawValue ?? "bin"
        let name = "\(UUID().uuidString).\(ext)"
        let destination = folder(serverID).appendingPathComponent(name)
        try prepareDirectory(serverID)
        // A hard link gives automatic and manual retention independent lifetimes without copying audio.
        do { try FileManager.default.linkItem(at: source, to: destination) }
        catch { try FileManager.default.copyItem(at: source, to: destination) }
        do {
            let size = Int64(try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            guard size > 0 else { throw CocoaError(.fileReadCorruptFile) }
            let previous = value.files[songID]
            value.files[songID] = FileEntry(filename: name, size: size)
            try save(value, serverID: serverID)
            if let previous { try? FileManager.default.removeItem(at: fileURL(previous, serverID: serverID)) }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    func localAlbumData(albumID: String, serverID: UUID) -> LocalAlbumData? {
        guard let album = try? snapshot(serverID: serverID).albums[albumID] else { return nil }
        let songs = (album.song ?? []).filter { localURL(songID: $0.id, serverID: serverID) != nil }
            .map { DisplayableSong(from: $0) }
        guard !songs.isEmpty else { return nil }
        return LocalAlbumData(albumId: album.id, albumName: album.name, artistName: album.artist,
                              coverArtId: album.coverArt, songs: songs)
    }

    func invalidate(songID: String, serverID: UUID) throws {
        var value = try snapshot(serverID: serverID)
        guard let old = value.files.removeValue(forKey: songID) else { return }
        try save(value, serverID: serverID)
        try? FileManager.default.removeItem(at: fileURL(old, serverID: serverID))
    }

    func clearAudio() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        for child in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            guard let serverID = UUID(uuidString: child.lastPathComponent) else { continue }
            var value = try snapshot(serverID: serverID)
            value.files = [:]
            try save(value, serverID: serverID)
            for file in try FileManager.default.contentsOfDirectory(at: child, includingPropertiesForKeys: nil)
            where file.lastPathComponent != "catalog.json" {
                try FileManager.default.removeItem(at: file)
            }
        }
    }

    func removeServer(_ serverID: UUID) throws {
        defer { Task { @MainActor in postOfflineLibraryChanged() } }
        let url = folder(serverID)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        snapshots.removeValue(forKey: serverID)
    }

    func usage() throws -> Usage {
        guard FileManager.default.fileExists(atPath: directory.path) else { return Usage() }
        var result = Usage()
        for child in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            guard let id = UUID(uuidString: child.lastPathComponent) else { continue }
            for (songID, entry) in try snapshot(serverID: id).files where localURL(songID: songID, serverID: id) != nil {
                result.count += 1
                result.bytes += entry.size
            }
        }
        return result
    }

    private func folder(_ serverID: UUID) -> URL { directory.appendingPathComponent(serverID.uuidString) }

    private func fileURL(_ entry: FileEntry, serverID: UUID) -> URL {
        folder(serverID).appendingPathComponent(URL(fileURLWithPath: entry.filename).lastPathComponent)
    }

    private func prepareDirectory(_ serverID: UUID) throws {
        var url = folder(serverID)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    private func save(_ value: Snapshot, serverID: UUID) throws {
        defer { Task { @MainActor in postOfflineLibraryChanged() } }
        try Task.checkCancellation()
        try prepareDirectory(serverID)
        try JSONEncoder().encode(value).write(to: folder(serverID).appendingPathComponent("catalog.json"), options: .atomic)
        snapshots[serverID] = value
    }
}
