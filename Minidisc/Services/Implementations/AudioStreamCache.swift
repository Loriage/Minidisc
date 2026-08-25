import Foundation
import SwiftData
import OSLog

/// Streaming cache for recently-played tracks. Holds a byte-bounded sliding window and evicts
/// least-recently-used entries when the configured capacity is exceeded.
///
/// Caches AUDIO BYTES ONLY. It holds no library metadata — no albums, artists, playlists or search
/// results. The separate library index contains discardable metadata but never audio bytes.
///
/// Distinct from DownloadService:
/// - DownloadService → permanent, user-explicit, never auto-evicted, lives in Documents/.
/// - AudioStreamCache → transient, automatic, evicted by LRU, lives in Caches/.
///
/// Populated via the streaming hook in PlayerService. MediaResolver reads from this cache
/// between permanent downloads and remote streaming.
actor AudioStreamCache: AudioStreamCacheProtocol {
    private let modelContainer: ModelContainer
    private lazy var modelContext: ModelContext = ModelContext(modelContainer)
    private let cacheDirectory: URL
    private(set) var maxBytes: Int64

    nonisolated static let defaultMaxBytes: Int64 = 512 * 1_000_000
    // The UI enforces a user-facing 128 MB minimum. Keeping the service minimum at one byte
    // makes the byte-budget invariant independently testable and useful to non-UI callers.
    nonisolated static let minMaxBytes: Int64 = 1
    nonisolated static let maxMaxBytes: Int64 = 2_048 * 1_000_000

    init(modelContainer: ModelContainer, maxBytes: Int64 = AudioStreamCache.defaultMaxBytes) {
        self.modelContainer = modelContainer
        self.maxBytes = max(Self.minMaxBytes, min(Self.maxMaxBytes, maxBytes))

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.cacheDirectory = caches.appendingPathComponent("app.minidisc/audio", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        } catch {
            Logger.cache.debug("AudioStreamCache: failed to create cache directory — \(error)")
        }
    }

    // MARK: - Configuration

    /// Updates the byte capacity and immediately evicts least-recently-used entries if needed.
    func setMaxBytes(_ value: Int64) async {
        maxBytes = max(Self.minMaxBytes, min(Self.maxMaxBytes, value))
        await evictToFitBudget()
    }

    // MARK: - Lookup

    func cachedURL(forSongId songId: String, serverId: UUID) async -> URL? {
        let sid = serverId
        var descriptor = FetchDescriptor<CachedTrack>(
            predicate: #Predicate { $0.songId == songId && $0.serverId == sid }
        )
        descriptor.fetchLimit = 1
        let tracks = (try? modelContext.fetch(descriptor)) ?? []
        guard let entry = tracks.first else { return nil }
        let url = cacheDirectory.appendingPathComponent(entry.filePath)
        // Self-healing covers missing, empty, and size-mismatched files — a partial or
        // corrupt cache file must fall through to stream, never reach the player.
        let diskSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        guard diskSize > 0, diskSize == entry.fileSize else {
            Logger.cache.warning("Cache record exists but file missing or invalid (disk \(diskSize) bytes, record \(entry.fileSize)): \(entry.filePath, privacy: .public)")
            await invalidate(songId: songId, serverId: serverId)
            return nil
        }
        entry.cachedAt = Date()
        do {
            try modelContext.save()
        } catch {
            Logger.cache.debug("AudioStreamCache: failed to persist LRU access — \(error)")
        }
        return url
    }

    // MARK: - Storage

    /// Moves a completed download into the cache. Upserts the SwiftData record, then runs LRU eviction.
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
        let storedTrackID: UUID
        do {
            let sid = serverId
            var descriptor = FetchDescriptor<CachedTrack>(
                predicate: #Predicate { $0.songId == songId && $0.serverId == sid }
            )
            descriptor.fetchLimit = 1
            let existing = try modelContext.fetch(descriptor).first
            previousPath = existing?.filePath
            if let existing {
                existing.filePath = relativePath
                existing.fileSize = fileSize
                existing.mimeType = mimeType
                existing.cachedAt = Date()
                storedTrackID = existing.id
            } else {
                let cachedTrack = CachedTrack(
                    songId: songId,
                    serverId: serverId,
                    filePath: relativePath,
                    fileSize: fileSize,
                    mimeType: mimeType
                )
                modelContext.insert(cachedTrack)
                storedTrackID = cachedTrack.id
            }
            try modelContext.save()
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            throw error
        }
        if let previousPath, previousPath != relativePath {
            try? FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent(previousPath))
        }

        // Preserve the just-written file so this method never returns a URL it evicted. A single
        // unusually large track may temporarily exceed the soft budget until the next trim.
        await evictToFitBudget(protecting: storedTrackID)
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

    /// Removes least-recently-used tracks until their recorded byte total fits the budget.
    private func evictToFitBudget(protecting protectedID: UUID? = nil) async {
        let descriptor = FetchDescriptor<CachedTrack>(sortBy: [SortDescriptor(\.cachedAt, order: .forward)])
        let allTracks = (try? modelContext.fetch(descriptor)) ?? []
        var remainingBytes = allTracks.reduce(Int64.zero) { $0 + max(0, $1.fileSize) }
        guard remainingBytes > maxBytes else { return }

        var toEvict: [(filePath: String, id: UUID, fileSize: Int64)] = []
        for track in allTracks where remainingBytes > maxBytes {
            guard track.id != protectedID else { continue }
            toEvict.append((track.filePath, track.id, track.fileSize))
            remainingBytes -= max(0, track.fileSize)
        }

        for entry in toEvict {
            do {
                try FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent(entry.filePath))
            } catch {
                Logger.cache.debug("AudioStreamCache: evict removeItem failed — \(error)")
            }
        }

        let recordIds = Set(toEvict.map { $0.id })
        allTracks.filter { recordIds.contains($0.id) }.forEach { modelContext.delete($0) }
        do {
            try modelContext.save()
        } catch {
            Logger.cache.debug("AudioStreamCache: evict save failed — \(error)")
        }

        Logger.cache.info("Evicted \(toEvict.count) least-recently-used cache entries")
        if remainingBytes > maxBytes {
            Logger.cache.warning(
                "Newest cached track exceeds the configured byte budget (\(remainingBytes) > \(self.maxBytes))"
            )
        }
    }

    /// Manually invalidates a single entry (file + record). No-op if not cached.
    func invalidate(songId: String, serverId: UUID) async {
        let sid = serverId
        let matchingTracks = (try? modelContext.fetch(
            FetchDescriptor<CachedTrack>(
                predicate: #Predicate { $0.songId == songId && $0.serverId == sid }
            )
        )) ?? []
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
