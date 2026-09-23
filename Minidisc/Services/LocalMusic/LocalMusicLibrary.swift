import AVFoundation
import CryptoKit
import Foundation
import Observation
import UniformTypeIdentifiers

nonisolated struct LocalFileReference: Codable, Hashable, Sendable {
    let folderID: UUID
    let relativePath: String

    var id: String {
        "local:" + SHA256.hash(data: Data("\(folderID)/\(relativePath)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func url(in root: URL) throws -> URL {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/").contains("..") else { throw LocalMusicError.unavailable }
        var componentURL = root
        for component in relativePath.split(separator: "/") {
            componentURL.appendPathComponent(String(component))
            if (try? componentURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw LocalMusicError.unavailable
            }
        }
        let url = root.appendingPathComponent(relativePath).standardizedFileURL
        guard url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else {
            throw LocalMusicError.unavailable
        }
        return url
    }
}

nonisolated enum LocalMusicError: Error, LocalizedError, Codable, Equatable {
    case unavailable, folderAccess, unsupported

    var errorDescription: String? {
        switch self {
        case .unavailable: String(localized: "This file is unavailable. Download or restore it in Files, then refresh Minidisc.", table: "LocalMusic")
        case .folderAccess: String(localized: "This folder is unavailable. Check its location and permissions in Files, or add it again.", table: "LocalMusic")
        case .unsupported: String(localized: "This audio file cannot be played on this device.", table: "LocalMusic")
        }
    }
}

/// The player and its standby item retain this lease for as long as AVPlayer uses the URL.
nonisolated final class LocalFileAccess: Sendable {
    let url: URL
    private let root: URL
    private let scoped: Bool

    init(root: URL, reference: LocalFileReference) throws {
        self.root = root
        scoped = root.startAccessingSecurityScopedResource()
        do {
            url = try reference.url(in: root)
            guard try LocalMusicStore.isAvailable(url) else { throw LocalMusicError.unavailable }
        } catch {
            if scoped { root.stopAccessingSecurityScopedResource() }
            throw LocalMusicError.unavailable
        }
    }

    deinit { if scoped { root.stopAccessingSecurityScopedResource() } }
}

nonisolated struct LocalMusicFolder: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var bookmark: Data
    var isAccessible = true
}

nonisolated struct LocalMusicTrack: Identifiable, Codable, Equatable, Sendable {
    var song: DisplayableSong
    var modified: Date?
    var size: Int?
    var isAvailable: Bool
    var addedAt: Date? = nil
    var id: String { song.id }
}

nonisolated struct LocalMusicSnapshot: Codable, Equatable, Sendable {
    var folders: [LocalMusicFolder] = []
    var tracks: [LocalMusicTrack] = []
}

actor LocalMusicStore {
    private let directory: URL
    private var snapshot: LocalMusicSnapshot
    private var revision = 0

    init(directory: URL) {
        self.directory = directory
        snapshot = (try? Data(contentsOf: directory.appendingPathComponent("index.json")))
            .flatMap { try? JSONDecoder().decode(LocalMusicSnapshot.self, from: $0) } ?? LocalMusicSnapshot()
    }

    func current() -> LocalMusicSnapshot { snapshot }

    func add(_ urls: [URL]) throws {
        var updated = snapshot
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                throw LocalMusicError.folderAccess
            }
            let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            if let index = updated.folders.firstIndex(where: { (try? resolve($0).standardizedFileURL) == url.standardizedFileURL }) {
                updated.folders[index].bookmark = bookmark
                updated.folders[index].isAccessible = true
            } else {
                updated.folders.append(LocalMusicFolder(id: UUID(), name: url.lastPathComponent, bookmark: bookmark))
            }
        }
        try persist(updated)
        snapshot = updated
        revision += 1
    }

    func remove(_ id: UUID) throws {
        var updated = snapshot
        updated.folders.removeAll { $0.id == id }
        updated.tracks.removeAll { $0.song.localFile?.folderID == id }
        try persist(updated)
        let removedIDs = Set(snapshot.tracks.map(\.id)).subtracting(updated.tracks.map(\.id))
        snapshot = updated
        revision += 1
        for id in removedIDs { try? FileManager.default.removeItem(at: artworkURL(id)) }
    }

    func access(_ reference: LocalFileReference) throws -> LocalFileAccess {
        guard let folder = snapshot.folders.first(where: { $0.id == reference.folderID }) else {
            throw LocalMusicError.folderAccess
        }
        guard let root = try? resolve(folder) else { throw LocalMusicError.folderAccess }
        return try LocalFileAccess(root: root, reference: reference)
    }

    func artwork(_ id: String) -> Data? {
        guard id.hasPrefix("local:"), id.dropFirst(6).allSatisfy(\.isHexDigit) else { return nil }
        return try? Data(contentsOf: artworkURL(id))
    }

    func refresh() async throws -> LocalMusicSnapshot {
        let generation = revision
        let scanDate = Date()
        var updated = snapshot
        var tracks: [LocalMusicTrack] = []
        let existing = Dictionary(snapshot.tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seenURLs = Set<URL>()
        for index in updated.folders.indices {
            try Task.checkCancellation()
            let folder = updated.folders[index]
            do {
                var stale = false
                let root = try URL(resolvingBookmarkData: folder.bookmark, options: [.withoutUI], bookmarkDataIsStale: &stale)
                let scoped = root.startAccessingSecurityScopedResource()
                defer { if scoped { root.stopAccessingSecurityScopedResource() } }
                if stale {
                    updated.folders[index].bookmark = try root.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
                }
                let files = try Self.listAudioFiles(root)
                updated.folders[index].isAccessible = true
                updated.folders[index].name = root.lastPathComponent
                for url in files {
                    try Task.checkCancellation()
                    guard seenURLs.insert(url.standardizedFileURL).inserted else { continue }
                    let relative = String(url.path.dropFirst(root.path.count + 1))
                    let reference = LocalFileReference(folderID: folder.id, relativePath: relative)
                    let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                    let available = (try? Self.isAvailable(url)) == true
                    var track = existing[reference.id] ?? Self.placeholder(reference)
                    if available && (track.modified != values?.contentModificationDate || track.size != values?.fileSize || !track.isAvailable) {
                        track = await readMetadata(url, reference: reference, previous: track)
                        track.modified = values?.contentModificationDate
                        track.size = values?.fileSize
                    }
                    track.addedAt = existing[reference.id]?.addedAt ?? existing[reference.id]?.modified ?? scanDate
                    track.isAvailable = available
                    tracks.append(track)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                updated.folders[index].isAccessible = false
                tracks += snapshot.tracks.filter { $0.song.localFile?.folderID == folder.id }.map {
                    var track = $0
                    track.isAvailable = false
                    return track
                }
            }
        }
        guard generation == revision else { return snapshot }
        updated.tracks = tracks.sorted { $0.song.title.localizedStandardCompare($1.song.title) == .orderedAscending }
        try persist(updated)
        let removedIDs = Set(snapshot.tracks.map(\.id)).subtracting(updated.tracks.map(\.id))
        snapshot = updated
        for id in removedIDs { try? FileManager.default.removeItem(at: artworkURL(id)) }
        return updated
    }

    nonisolated static func isAvailable(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .fileAllocatedSizeKey])
        guard values.isRegularFile == true else { return false }
        return isDownloaded(isUbiquitous: values.isUbiquitousItem == true,
                            status: values.ubiquitousItemDownloadingStatus,
                            allocatedSize: values.fileAllocatedSize)
    }

    nonisolated static func isDownloaded(isUbiquitous: Bool, status: URLUbiquitousItemDownloadingStatus?, allocatedSize: Int?) -> Bool {
        if isUbiquitous && status != .current && status != .downloaded { return false }
        // Dataless placeholders from other file providers must not be opened to inspect their tags.
        return (allocatedSize ?? 0) > 0
    }

    nonisolated static func listAudioFiles(_ root: URL) throws -> [URL] {
        var result: [URL] = []
        var failure: NSError?
        var listingFailed = false
        NSFileCoordinator().coordinate(readingItemAt: root, options: .immediatelyAvailableMetadataOnly, error: &failure) { directory in
            let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .contentTypeKey]
            guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in
                listingFailed = true
                return false
            }) else {
                listingFailed = true
                return
            }
            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                if values.isRegularFile == true,
                   (values.contentType?.conforms(to: .audio) == true || ["mp3", "m4a", "aac", "flac", "wav", "aif", "aiff", "caf", "alac"].contains(url.pathExtension.lowercased())) {
                    result.append(url)
                }
            }
        }
        if failure != nil || listingFailed { throw LocalMusicError.folderAccess }
        return result
    }

    private func readMetadata(_ url: URL, reference: LocalFileReference, previous: LocalMusicTrack) async -> LocalMusicTrack {
        guard (try? Self.isAvailable(url)) == true else { return previous }
        let asset = AVURLAsset(url: url)
        guard (try? await asset.load(.isPlayable)) == true else { return previous }
        let metadata = (try? await asset.load(.commonMetadata)) ?? []
        func value(_ key: AVMetadataKey) async -> String? {
            guard let item = metadata.first(where: { $0.commonKey == key }) else { return nil }
            return try? await item.load(.stringValue)
        }
        let title = await value(.commonKeyTitle) ?? url.deletingPathExtension().lastPathComponent
        let artist = await value(.commonKeyArtist)
        let album = await value(.commonKeyAlbumName)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let allMetadata = (try? await asset.load(.metadata)) ?? []
        var trackNumber: Int?
        var discNumber: Int?
        for item in allMetadata {
            if item.identifier == .id3MetadataTrackNumber, let text = try? await item.load(.stringValue) {
                trackNumber = text.split(separator: "/").first.flatMap { Int($0) }
            }
            if item.identifier == .iTunesMetadataTrackNumber, let data = try? await item.load(.dataValue), data.count >= 4 {
                trackNumber = Int(data[2]) * 256 + Int(data[3])
            }
            if item.identifier == .iTunesMetadataDiscNumber, let data = try? await item.load(.dataValue), data.count >= 4 {
                discNumber = Int(data[2]) * 256 + Int(data[3])
            }
        }
        var coverID: String?
        if let item = metadata.first(where: { $0.commonKey == .commonKeyArtwork }),
           let data = try? await item.load(.dataValue), data.count < 20_000_000 {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: artworkURL(reference.id), options: .atomic)
                coverID = reference.id
            } catch { }
        }
        let song = DisplayableSong(id: reference.id, title: title, artist: artist, albumId: nil, albumName: album,
                                   artistId: nil, genre: nil, duration: duration.isFinite ? duration : 0,
                                   discNumber: discNumber, trackNumber: trackNumber, isDownloaded: false, coverArtId: coverID,
                                   audioFormat: url.pathExtension.uppercased(), replayGainTrackGain: nil,
                                   replayGainTrackPeak: nil, replayGainAlbumGain: nil, replayGainAlbumPeak: nil,
                                   replayGainBaseGain: nil, replayGainFallbackGain: nil, localFile: reference)
        return LocalMusicTrack(song: song, modified: previous.modified, size: previous.size, isAvailable: true)
    }

    nonisolated static func placeholder(_ reference: LocalFileReference) -> LocalMusicTrack {
        let song = DisplayableSong(id: reference.id, title: URL(fileURLWithPath: reference.relativePath).deletingPathExtension().lastPathComponent,
                                   artist: nil, albumId: nil, albumName: nil, artistId: nil, genre: nil, duration: 0,
                                   trackNumber: nil, isDownloaded: false, coverArtId: nil, audioFormat: nil,
                                   replayGainTrackGain: nil, replayGainTrackPeak: nil, replayGainAlbumGain: nil,
                                   replayGainAlbumPeak: nil, replayGainBaseGain: nil, replayGainFallbackGain: nil, localFile: reference)
        return LocalMusicTrack(song: song, isAvailable: false)
    }

    private func resolve(_ folder: LocalMusicFolder) throws -> URL {
        var stale = false
        return try URL(resolvingBookmarkData: folder.bookmark, options: [.withoutUI], bookmarkDataIsStale: &stale)
    }

    private func artworkURL(_ id: String) -> URL { directory.appendingPathComponent(String(id.dropFirst(6)) + ".artwork") }

    private func persist(_ value: LocalMusicSnapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: directory.appendingPathComponent("index.json"), options: .atomic)
    }
}

@Observable @MainActor
final class LocalMusicLibrary {
    let store: LocalMusicStore
    private(set) var snapshot = LocalMusicSnapshot()
    private(set) var isRefreshing = false
    @ObservationIgnored private var refreshRequested = false
    var errorMessage: String?

    init(store: LocalMusicStore) { self.store = store }

    func refresh() async {
        guard !isRefreshing else { refreshRequested = true; return }
        isRefreshing = true
        defer {
            isRefreshing = false
            if refreshRequested {
                refreshRequested = false
                Task { await refresh() }
            }
        }
        snapshot = await store.current()
        do { snapshot = try await store.refresh() }
        catch is CancellationError { }
        catch { errorMessage = error.localizedDescription }
    }

    func add(_ urls: [URL]) async {
        do { try await store.add(urls); await refresh() }
        catch { errorMessage = LocalMusicError.folderAccess.localizedDescription }
    }

    func remove(_ folder: LocalMusicFolder) async {
        do { try await store.remove(folder.id); snapshot = await store.current() }
        catch { errorMessage = error.localizedDescription }
    }
}
