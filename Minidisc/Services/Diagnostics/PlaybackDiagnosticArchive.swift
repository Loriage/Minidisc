import Foundation

/// Persists already-redacted text off the playback threads. No media URL or event payload enters this store.
nonisolated final class PlaybackDiagnosticArchive: @unchecked Sendable {
    struct Session: Codable, Sendable {
        let id: UUID
        let startedAt: Date
        let environment: String
        var text: String
    }

    static let maximumFileBytes = 2 * 1_024 * 1_024
    private let directory: URL
    private let sessionID: UUID
    private let queue = DispatchQueue(label: "minidisc.diagnostics.archive", qos: .utility)
    // The following state is confined to queue.
    private var pending: (@Sendable () -> Session?)?
    private var scheduled = false
    private var lastWrite = Date.distantPast
    private var writeFailed = false

    init(directory: URL, sessionID: UUID) {
        self.directory = directory
        self.sessionID = sessionID
    }

    static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appendingPathComponent("PlaybackDiagnostics", isDirectory: true)
    }

    func schedule(urgent: Bool, snapshot: @escaping @Sendable () -> Session?) {
        queue.async { [self] in
            pending = snapshot
            if urgent, Date().timeIntervalSince(lastWrite) >= 2 { writePending() }
            guard !scheduled, pending != nil else { return }
            scheduled = true
            queue.asyncAfter(deadline: .now() + 30) { [self] in
                scheduled = false
                writePending()
            }
        }
    }

    func flush() { queue.sync { writePending() } }

    func previousSessions() -> (sessions: [Session], writeFailed: Bool) {
        queue.sync {
            writePending()
            let sessions = loadSessions().filter { $0.id != sessionID }.sorted { $0.startedAt > $1.startedAt }.prefix(3)
            return (Array(sessions.reversed()), writeFailed)
        }
    }

    private func loadSessions() -> [Session] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return urls.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= Self.maximumFileBytes,
                  let data = try? Data(contentsOf: url),
                  let session = try? JSONDecoder().decode(Session.self, from: data),
                  Date().timeIntervalSince(session.startedAt) < 7 * 86_400 else {
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            return session
        }
    }

    private func writePending() {
        guard let snapshot = pending else { return }
        pending = nil
        guard let session = snapshot() else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var directory = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            let data = try JSONEncoder().encode(session)
            guard data.count <= Self.maximumFileBytes else { writeFailed = true; return }
            let destination = directory.appendingPathComponent("\(sessionID.uuidString).json")
            try data.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            lastWrite = Date()
            writeFailed = false
            // Current session + three previous launches, with a maximum age of seven days.
            let previous = loadSessions().filter { $0.id != sessionID }.sorted { $0.startedAt > $1.startedAt }
            for old in previous.dropFirst(3) {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(old.id.uuidString).json"))
            }
        } catch {
            writeFailed = true
        }
    }
}
