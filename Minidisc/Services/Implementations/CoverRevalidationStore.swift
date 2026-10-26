import Foundation
import OSLog

/// Compares Last-Modified from HEAD responses because Navidrome does not return 304 here.
nonisolated enum CoverRevalidationOutcome: Equatable {
    /// First time we check this cover: adopt the server value as the baseline, keep the image.
    case baseline
    case unchanged
    case changed
    /// No usable `Last-Modified` header (server didn't send one). Cannot tell; leave things be.
    case indeterminate

    static func decide(stored: String?, server: String?) -> CoverRevalidationOutcome {
        guard let server, !server.isEmpty else { return .indeterminate }
        guard let stored, !stored.isEmpty else { return .baseline }
        return server == stored ? .unchanged : .changed
    }
}

/// Cover IDs may stay unchanged when artwork is replaced. Persist Last-Modified and
/// check times to detect those changes; coalesce writes during cache warmup.
@MainActor
final class CoverRevalidationStore {
    struct Entry: Codable, Equatable {
        var lastModified: String?
        var lastChecked: Date
    }

    nonisolated static let defaultTTL: TimeInterval = 7 * 24 * 3600

    private var entries: [String: Entry]
    private let fileURL: URL
    private var pendingSave: Task<Void, Never>?

    nonisolated init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        if let data = try? Data(contentsOf: self.fileURL),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        } else {
            entries = [:]
        }
    }

    func isDue(id: String, now: Date = Date(), ttl: TimeInterval = defaultTTL) -> Bool {
        guard let entry = entries[id] else { return true }
        return now.timeIntervalSince(entry.lastChecked) >= ttl
    }

    func lastModified(for id: String) -> String? { entries[id]?.lastModified }

    /// Records the outcome of a check (or a fresh fetch): stores the server's `Last-Modified` and
    /// resets the timer. Passing `nil` for `lastModified` keeps whatever was there.
    func record(id: String, lastModified: String?, checkedAt: Date = Date()) {
        let resolved = lastModified ?? entries[id]?.lastModified
        entries[id] = Entry(lastModified: resolved, lastChecked: checkedAt)
        scheduleSave()
    }

    /// Forgets one cover after an explicit invalidation so a later fetch establishes a fresh
    /// `Last-Modified` baseline instead of comparing against metadata for deleted bytes.
    func remove(id: String) {
        guard entries.removeValue(forKey: id) != nil else { return }
        scheduleSave()
    }

    /// Forgets everything — used by the version-bump cache wipe so stale metadata never outlives the
    /// images it described.
    func removeAll() {
        entries.removeAll()
        pendingSave?.cancel()
        pendingSave = nil
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Writes any pending changes to disk immediately, bypassing the debounce. Tests use this to
    /// avoid depending on the coalescing timer.
    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        saveNow()
    }

    private func scheduleSave() {
        guard pendingSave == nil else { return }
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.saveNow()
            self?.pendingSave = nil
        }
    }

    private func saveNow() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Logger.artworkCache.warning("[REVAL] could not persist revalidation store: \(error, privacy: .public)")
        }
    }

    nonisolated private static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("app.minidisc", isDirectory: true)
        return base.appendingPathComponent("coverart-revalidation.json")
    }
}
