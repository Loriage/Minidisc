import Foundation
import SwiftData
import OSLog

/// Streaming cache for recently-played tracks. Holds a sliding window of the N most-recently-cached tracks.
/// FIFO eviction: when count exceeds the limit, the oldest by `cachedAt` is removed (file + record).
///
/// Caches AUDIO BYTES ONLY. It holds no library metadata — no albums, artists, playlists or search
/// results — and the app has no metadata cache at all: LibraryService goes to the server on every call.
/// Nothing here makes the library browsable offline; only the downloads store does.
///
/// Distinct from DownloadService:
/// - DownloadService → permanent, user-explicit, never auto-evicted, lives in Documents/.
/// - AudioStreamCache → transient, automatic, evicted by FIFO, lives in Caches/.
///
/// Populated via the streaming hook in PlayerService. MediaResolver reads from this cache
/// between permanent downloads and remote streaming.
actor AudioStreamCache: AudioStreamCacheProtocol {
    private let modelContainer: ModelContainer
    private lazy var modelContext: ModelContext = ModelContext(modelContainer)
    private let cacheDirectory: URL
    private(set) var maxTracks: Int

    nonisolated static let defaultMaxTracks: Int = 10
    nonisolated static let minMaxTracks: Int = 1
    nonisolated static let maxMaxTracks: Int = 10

    init(modelContainer: ModelContainer, maxTracks: Int = AudioStreamCache.defaultMaxTracks) {
        self.modelContainer = modelContainer
        self.maxTracks = max(Self.minMaxTracks, min(Self.maxMaxTracks, maxTracks))

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.cacheDirectory = caches.appendingPathComponent("app.minidisc/audio", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        } catch {
            Logger.cache.debug("AudioStreamCache: failed to create cache directory — \(error)")
        }
    }

    // MARK: - Configuration

    /// Updates the maximum number of tracks held in cache. Triggers FIFO eviction if count exceeds
    /// the new limit. Range is clamped to [1, 10].
    func setMaxTracks(_ value: Int) async {
        maxTracks = max(Self.minMaxTracks, min(Self.maxMaxTracks, value))
        await evictToFitLimit()
    }

    // MARK: - Lookup

    func cachedURL(forSongId songId: String, serverId: UUID) async -> URL? {
        var descriptor = FetchDescriptor<CachedTrack>(predicate: #Predicate { $0.songId == songId })
        descriptor.fetchLimit = 1
        let tracks = (try? modelContext.fetch(descriptor)) ?? []
        let entry = tracks.first { $0.serverId == serverId }.map {
            (filePath: $0.filePath, fileSize: $0.fileSize)
        }
        guard let entry else { return nil }
        let url = cacheDirectory.appendingPathComponent(entry.filePath)
        // Self-healing covers missing, empty, and size-mismatched files — a partial or
        // corrupt cache file must fall through to stream, never reach the player.
        let diskSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        guard diskSize > 0, diskSize == entry.fileSize else {
            Logger.cache.warning("Cache record exists but file missing or invalid (disk \(diskSize) bytes, record \(entry.fileSize)): \(entry.filePath, privacy: .public)")
            await invalidate(songId: songId, serverId: serverId)
            return nil
        }
        return url
    }

    // MARK: - Storage

    /// Moves a completed download into the cache. Upserts the SwiftData record, then runs FIFO eviction.
    func store(fileAt sourceURL: URL, forSongId songId: String, serverId: UUID, mimeType: String) async throws -> URL {
        let ext = audioExtension(mimeType: mimeType)
        // Song IDs are server-controlled and may contain path separators. A generated basename keeps
        // every entry inside the flat cache directory.
        let relativePath = "\(serverId.uuidString)-\(UUID().uuidString).\(ext)"
        let fileURL = cacheDirectory.appendingPathComponent(relativePath)

        do {
            try FileManager.default.moveItem(at: sourceURL, to: fileURL)
        } catch {
            // A temporary URL can live on another volume, where rename is unavailable.
            try FileManager.default.copyItem(at: sourceURL, to: fileURL)
        }
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
        guard fileSize > 0 else {
            try? FileManager.default.removeItem(at: fileURL)
            throw CocoaError(.fileReadCorruptFile)
        }

        let previousPath: String?
        do {
            let existing = try modelContext.fetch(FetchDescriptor<CachedTrack>(predicate: #Predicate { $0.songId == songId }))
                .first { $0.serverId == serverId }
            previousPath = existing?.filePath
            if let existing {
                existing.filePath = relativePath
                existing.fileSize = fileSize
                existing.mimeType = mimeType
                existing.cachedAt = Date()
            } else {
                modelContext.insert(CachedTrack(
                    songId: songId,
                    serverId: serverId,
                    filePath: relativePath,
                    fileSize: fileSize,
                    mimeType: mimeType
                ))
            }
            try modelContext.save()
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            throw error
        }
        if let previousPath, previousPath != relativePath {
            try? FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent(previousPath))
        }

        await evictToFitLimit()
        Logger.cache.info("Cached '\(songId, privacy: .public)' (\(fileSize) bytes, \(mimeType, privacy: .public))")
        return fileURL
    }

    private func audioExtension(mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "audio/mpeg", "audio/mp3":          return "mp3"
        case "audio/flac", "audio/x-flac":       return "flac"
        case "audio/mp4", "audio/m4a",
             "audio/aac", "audio/x-aac":         return "m4a"
        case "audio/ogg":                         return "ogg"
        case "audio/opus":                        return "opus"
        case "audio/wav", "audio/x-wav":         return "wav"
        case "audio/aiff", "audio/x-aiff":       return "aiff"
        default:                                  return "bin"
        }
    }

    // MARK: - Eviction

    /// FIFO eviction: removes the oldest tracks (by cachedAt asc) until count <= maxTracks.
    private func evictToFitLimit() async {
        let descriptor = FetchDescriptor<CachedTrack>(sortBy: [SortDescriptor(\.cachedAt, order: .forward)])
        let allTracks = (try? modelContext.fetch(descriptor)) ?? []
        let excess = allTracks.count - maxTracks
        guard excess > 0 else { return }
        let toEvict = allTracks.prefix(excess).map { ($0.filePath, $0.id) }

        for (filePath, _) in toEvict {
            do {
                try FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent(filePath))
            } catch {
                Logger.cache.debug("AudioStreamCache: evict removeItem failed — \(error)")
            }
        }

        let recordIds = Set(toEvict.map { $0.1 })
        allTracks.filter { recordIds.contains($0.id) }.forEach { modelContext.delete($0) }
        do {
            try modelContext.save()
        } catch {
            Logger.cache.debug("AudioStreamCache: evict save failed — \(error)")
        }

        Logger.cache.info("Evicted \(toEvict.count) cache entries (FIFO, oldest first)")
    }

    /// Manually invalidates a single entry (file + record). No-op if not cached.
    func invalidate(songId: String, serverId: UUID) async {
        let tracks = (try? modelContext.fetch(FetchDescriptor<CachedTrack>(predicate: #Predicate { $0.songId == songId }))) ?? []
        let matchingTracks = tracks.filter { $0.serverId == serverId }
        let filePath = matchingTracks.first?.filePath
        if let filePath {
            do {
                try FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent(filePath))
            } catch {
                Logger.cache.debug("AudioStreamCache: invalidate removeItem failed — \(error)")
            }
        }
        matchingTracks.forEach { modelContext.delete($0) }
        do {
            try modelContext.save()
        } catch {
            Logger.cache.debug("AudioStreamCache: invalidate save failed — \(error)")
        }
        Logger.cache.debug("Invalidated cache for '\(songId, privacy: .public)'")
    }

    /// Clears the entire cache (all servers).
    func clearAll() async {
        let tracks = (try? modelContext.fetch(FetchDescriptor<CachedTrack>())) ?? []
        for filePath in tracks.map(\.filePath) {
            do {
                try FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent(filePath))
            } catch {
                Logger.cache.debug("AudioStreamCache: clearAll removeItem failed — \(error)")
            }
        }
        tracks.forEach { modelContext.delete($0) }
        do {
            try modelContext.save()
        } catch {
            Logger.cache.debug("AudioStreamCache: clearAll tracks save failed — \(error)")
        }
        Logger.cache.info("Cleared all cache entries")
    }

    /// Clears all cache entries for a specific server.
    func clearAllForServer(_ serverId: UUID) async {
        let allTracks = (try? modelContext.fetch(FetchDescriptor<CachedTrack>())) ?? []
        let tracks = allTracks.filter { $0.serverId == serverId }
        for filePath in tracks.map(\.filePath) {
            do {
                try FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent(filePath))
            } catch {
                Logger.cache.debug("AudioStreamCache: clearAllForServer removeItem failed — \(error)")
            }
        }
        tracks.forEach { modelContext.delete($0) }
        do {
            try modelContext.save()
        } catch {
            Logger.cache.debug("AudioStreamCache: clearAllForServer tracks save failed — \(error)")
        }
        Logger.cache.info("Cleared cache for server \(serverId.uuidString)")
    }

    // MARK: - Reporting

    /// Total bytes used by all cached tracks. Used by Settings UI.
    var usedBytes: Int64 {
        get async {
            let tracks = (try? modelContext.fetch(FetchDescriptor<CachedTrack>())) ?? []
            return tracks.map(\.fileSize).reduce(0, +)
        }
    }

    /// Number of cached tracks. Used by Settings UI.
    var trackCount: Int {
        get async {
            let tracks = (try? modelContext.fetch(FetchDescriptor<CachedTrack>())) ?? []
            return tracks.count
        }
    }
}
