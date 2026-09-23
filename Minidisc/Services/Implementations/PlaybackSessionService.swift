import Foundation
import SwiftData
import OSLog

actor PlaybackSessionService {
    private let modelContainer: ModelContainer
    // Lazy so the context is created on the actor's executor, not the MainActor caller of init.
    private lazy var modelContext: ModelContext = ModelContext(modelContainer)

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    func save(playerState: SessionPayload) {
        let session = fetchOrCreateSession()
        session.update(
            currentIndex: playerState.currentIndex,
            currentPosition: playerState.currentPosition,
            queue: playerState.queue,
            currentTrack: playerState.currentTrack,
            repeatMode: playerState.repeatMode
        )
        session.serverId = playerState.serverId
        do {
            try modelContext.save()
        } catch {
            Logger.session.warning("PlaybackSessionService: save failed — \(error)")
        }
        Logger.session.debug("Session saved: track='\(playerState.currentTrack?.title ?? "nil", privacy: .private)', pos=\(playerState.currentPosition, format: .fixed(precision: 1), privacy: .public)s, queue=\(playerState.queue.count, privacy: .public) tracks")
    }

    func savePosition(_ position: TimeInterval) {
        guard let session = fetchSession() else { return }
        session.currentPosition = position
        session.lastUpdated = Date()
        do {
            try modelContext.save()
        } catch {
            Logger.session.warning("PlaybackSessionService: savePosition failed — \(error)")
        }
    }

    func loadRestoredSession(serverID: UUID?) -> RestoredSession? {
        guard let session = fetchSession() else { return nil }
        if let saved = session.serverId, saved != serverID,
           !session.decodedQueue().allSatisfy(\.isLocalFile) { return nil }
        if session.serverId == nil, let serverID {
            session.serverId = serverID
            try? modelContext.save()
        }
        return loadRestoredSession()
    }

    /// Extracts and returns restoration data, keeping @Model objects on this actor's context.
    func loadRestoredSession() -> RestoredSession? {
        guard let session = fetchSession() else {
            Logger.session.info("No persisted session found")
            return nil
        }
        let queue = session.decodedQueue()
        guard !queue.isEmpty else {
            Logger.session.info("Persisted session has empty queue — skipping restore")
            return nil
        }
        let safeIndex = max(0, min(session.currentIndex, queue.count - 1))
        let rawPosition = session.currentPosition
        let safePosition = rawPosition.isFinite ? max(0, rawPosition) : 0
        let rawDuration = session.currentTrackDuration
        let safeDuration = rawDuration.isFinite ? max(0, rawDuration) : 0
        Logger.session.info("Session loaded: '\(session.currentTrackTitle ?? "nil", privacy: .private)', pos=\(safePosition, format: .fixed(precision: 1), privacy: .public)s, \(queue.count, privacy: .public) tracks")
        return RestoredSession(
            queue: queue,
            currentIndex: safeIndex,
            currentPosition: safePosition,
            currentTrackDuration: safeDuration,
            repeatMode: session.decodedRepeatMode()
        )
    }

    func clear() {
        guard let session = fetchSession() else { return }
        modelContext.delete(session)
        do {
            try modelContext.save()
        } catch {
            Logger.session.warning("PlaybackSessionService: clear save failed — \(error)")
        }
        Logger.session.info("Session cleared")
    }

    /// Before cold-start restoration only: the legacy singleton belongs to the
    /// persisted active server. Never migrate another server's session on a switch.
    func migrateNavidromeIDs() throws {
        guard let session = fetchSession(), !session.queueData.isEmpty,
              try NavidromeCanonicalID.containsLegacyIDs(in: session.queueData) else { return }
        let migrated = try NavidromeCanonicalID.songData(session.queueData)
        _ = try JSONDecoder().decode([DisplayableSong].self, from: migrated)
        session.queueData = migrated
        session.currentTrackId = session.currentTrackId.map(NavidromeCanonicalID.convert)
        session.currentTrackCoverArtId = session.currentTrackCoverArtId.map(NavidromeCanonicalID.artwork)
        try modelContext.save()
    }

    private func fetchOrCreateSession() -> PlaybackSession {
        if let existing = fetchSession() { return existing }
        let new = PlaybackSession()
        modelContext.insert(new)
        return new
    }

    private func fetchSession() -> PlaybackSession? {
        let descriptor = FetchDescriptor<PlaybackSession>(
            predicate: #Predicate { $0.id == "current" }
        )
        return try? modelContext.fetch(descriptor).first
    }
}

nonisolated struct SessionPayload: Sendable {
    let currentIndex: Int
    let currentPosition: TimeInterval
    let queue: [DisplayableSong]
    let currentTrack: DisplayableSong?
    let repeatMode: RepeatMode
    var serverId: UUID? = nil
}

nonisolated struct RestoredSession: Sendable {
    let queue: [DisplayableSong]
    let currentIndex: Int
    let currentPosition: TimeInterval
    let currentTrackDuration: TimeInterval
    let repeatMode: RepeatMode
}
