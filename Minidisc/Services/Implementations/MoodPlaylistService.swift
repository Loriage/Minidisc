import Foundation
import SwiftSonic
import OSLog

// MARK: - Results

nonisolated enum MoodSyncOutcome: Sendable, Equatable {
    /// No provider at all. Not reachable in production — the tag provider always exists — but kept
    /// so tests can exercise the branch and so a future provider can opt out.
    case notConfigured
    /// Every mood already refreshed for the current week.
    case upToDate
    /// An attempt was made too recently; backing off rather than retrying a dead endpoint.
    case throttled
    case finished(source: MoodSourceKind, refreshed: [Mood], kept: [Mood])
    case cancelled
}

/// Why a single mood was left alone. Its previous playlist stays exactly as it was.
nonisolated enum MoodSkipReason: Error, Sendable, Equatable {
    case searchFailed(String)
    case noResults
    case playlistWriteFailed(String)
    /// The server accepted the call and stored none of it — every track id was foreign to it.
    /// `sample` carries a few of the ids so the mismatch is visible in the log.
    case serverStoredNothing(sent: Int, sample: [String])
}

// MARK: - MoodPlaylistService

/// Maintains five server-side mood playlists, refreshed weekly.
///
/// Tracks come from AudioMuse's sonic analysis when it is configured, and from the server's own
/// MOOD/genre/BPM tags when it is not — so the feature exists on every server, and is better on
/// some. The choice is made once per run and recorded, because it changes how good the result is
/// and the user deserves to know which one they got.
///
/// Modelled on WrappedPlaylistService: a cadence marker in UserDefaults, playlists owned by the
/// server, and atomic replacement through createPlaylist's replace mode. The differences that
/// matter:
///
/// - **Five independent units of work.** A mood that fails keeps its old playlist and its old
///   marker, so the user still has last week's Workout rather than an empty one, and it retries by
///   itself. Nothing is ever cleared on failure.
/// - **Sequential, not parallel.** Instant Mix taught us that concurrent similarity queries on a
///   self-hosted box contend hard — eight parallel calls each took 22s against 12.8s solo. Five
///   moods one after another is friendlier and, on that evidence, probably not slower.
/// - **A prepare step.** AudioMuse evicts the CLAP model after ten minutes idle, so a weekly job
///   always arrives cold and pays the load up front rather than inside the first mood's timeout.
actor MoodPlaylistService {
    private let preferences: MoodPreferences
    private let makePlaylistClient: @Sendable () async throws -> any PlaylistSyncClient
    private let makeProvider: @Sendable () async -> (any MoodTrackProvider)?
    /// Renders and applies a playlist cover. Injected rather than called directly because
    /// PlaylistCoverManager is MainActor-bound and this is an actor.
    private let applyCover: (@Sendable (PlaylistGradientSpec, String, String) async -> Void)?

    /// Minimum gap between attempts, so an unreachable instance is not re-probed every launch.
    static let attemptThrottle: TimeInterval = 3600

    init(
        playlistClientFactory: @escaping @Sendable () async throws -> any PlaylistSyncClient,
        providerFactory: @escaping @Sendable () async -> (any MoodTrackProvider)?,
        coverApplier: (@Sendable (PlaylistGradientSpec, String, String) async -> Void)? = nil,
        preferences: MoodPreferences = MoodPreferences()
    ) {
        self.makePlaylistClient = playlistClientFactory
        self.makeProvider = providerFactory
        self.applyCover = coverApplier
        self.preferences = preferences
    }

    /// Production wiring. AudioMuse when it is configured and reachable-looking, the server's own
    /// tags otherwise — so the moods exist on every server, just better on some.
    init(
        serverService: any ServerServiceProtocol,
        serverState: ServerState,
        libraryService: any LibraryServiceProtocol,
        coverApplier: (@Sendable (PlaylistGradientSpec, String, String) async -> Void)? = nil,
        preferences: MoodPreferences = MoodPreferences()
    ) {
        self.preferences = preferences
        self.applyCover = coverApplier
        self.makePlaylistClient = { try await serverService.makeSwiftSonicClient() }
        self.makeProvider = {
            if let urlString = await MainActor.run(body: { serverState.activeServer?.audioMuseURL }),
               let credentials = try? await serverService.activeCredentials(),
               let client = AudioMuseClient(urlString: urlString, token: credentials.audioMuseToken) {
                return AudioMuseTrackProvider(client: client, resolver: SubsonicTrackResolver(libraryService: libraryService))
            }
            return LibraryTagTrackProvider(libraryService: libraryService)
        }
    }

    // MARK: - Sync

    /// Refreshes any mood whose playlist predates the current week.
    ///
    /// Safe to call on every launch: it is a no-op once the week's work is done, and throttled when
    /// the last attempt failed recently.
    func runWeeklySyncIfNeeded(
        serverId: String,
        calendar: Calendar = .current,
        currentDate: Date = Date()
    ) async -> MoodSyncOutcome {
        do {
            return try await runWeeklySyncIfNeededCancellable(
                serverId: serverId,
                calendar: calendar,
                currentDate: currentDate
            )
        } catch is CancellationError {
            return .cancelled
        } catch {
            Logger.moodPlaylists.error(
                "[MOOD-SYNC] unexpected failure: \(error, privacy: .public)"
            )
            return .cancelled
        }
    }

    /// Cancellation-preserving entry point used by BackgroundSyncCoordinator.
    /// A cancelled run never writes attempt/source markers after cancellation,
    /// and each completed mood remains an independent durable unit of progress.
    func runWeeklySyncIfNeededCancellable(
        serverId: String,
        calendar: Calendar = .current,
        currentDate: Date = Date()
    ) async throws -> MoodSyncOutcome {
        try Task.checkCancellation()
        let cycle = MoodCycle.start(for: currentDate, calendar: calendar)
        let pending = Mood.allCases.filter { mood in
            guard let synced = preferences.syncedCycle(mood: mood, serverId: serverId) else { return true }
            return synced < cycle
        }
        guard !pending.isEmpty else { return .upToDate }

        if let last = preferences.lastAttempt(serverId: serverId),
           currentDate.timeIntervalSince(last) < Self.attemptThrottle {
            Logger.moodPlaylists.debug("[MOOD-SYNC] throttled — last attempt \(Int(currentDate.timeIntervalSince(last)), privacy: .public)s ago")
            return .throttled
        }

        let provider = await makeProvider()
        try Task.checkCancellation()
        guard let provider else { return .notConfigured }

        let playlists: any PlaylistSyncClient
        do {
            playlists = try await makePlaylistClient()
        } catch {
            if error is CancellationError { throw CancellationError() }
            try Task.checkCancellation()
            Logger.moodPlaylists.error("[MOOD-SYNC] no Subsonic client: \(error, privacy: .public)")
            preferences.setLastAttempt(currentDate, serverId: serverId)
            return .finished(source: provider.kind, refreshed: [], kept: pending)
        }
        try Task.checkCancellation()

        await provider.prepare()
        try Task.checkCancellation()

        var refreshed: [Mood] = []
        var kept: [Mood] = []
        for mood in pending {
            try Task.checkCancellation()
            do {
                try await refresh(mood, serverId: serverId, cycle: cycle, provider: provider, playlists: playlists)
                refreshed.append(mood)
            } catch is CancellationError {
                throw CancellationError()
            } catch let reason as MoodSkipReason {
                kept.append(mood)
                Logger.moodPlaylists.warning("[MOOD-SYNC] \(mood.rawValue, privacy: .public) kept its previous playlist: \(String(describing: reason), privacy: .public)")
            } catch {
                kept.append(mood)
                Logger.moodPlaylists.warning("[MOOD-SYNC] \(mood.rawValue, privacy: .public) kept its previous playlist: \(error, privacy: .public)")
            }
        }

        try Task.checkCancellation()
        Logger.moodPlaylists.info("[MOOD-SYNC] source=\(provider.kind.rawValue, privacy: .public) refreshed \(refreshed.count, privacy: .public)/\(pending.count, privacy: .public) — kept \(kept.map(\.rawValue).joined(separator: ","), privacy: .public)")
        preferences.setLastAttempt(currentDate, serverId: serverId)
        preferences.setLastSource(provider.kind, serverId: serverId)
        return .finished(source: provider.kind, refreshed: refreshed, kept: kept)
    }

    /// Rebuilds all five playlists now, whatever the weekly cadence says.
    ///
    /// Called when the track source changes: connecting AudioMuse should replace the tag-built
    /// playlists immediately rather than leaving the user to wonder until Wednesday whether it took
    /// effect. Playlist ids are kept, so the existing playlists are rewritten in place.
    @discardableResult
    func rebuildNow(serverId: String, calendar: Calendar = .current, currentDate: Date = Date()) async -> MoodSyncOutcome {
        guard !Task.isCancelled else { return .cancelled }
        preferences.markAllDue(serverId: serverId)
        return await runWeeklySyncIfNeeded(serverId: serverId, calendar: calendar, currentDate: currentDate)
    }

    /// One mood, end to end. Throws `MoodSkipReason` so the caller can keep going; the marker is
    /// only advanced once the server has accepted the new track list.
    private func refresh(
        _ mood: Mood,
        serverId: String,
        cycle: Date,
        provider: any MoodTrackProvider,
        playlists: any PlaylistSyncClient
    ) async throws {
        try Task.checkCancellation()
        let trackIds: [String]
        do {
            trackIds = try await provider.trackIds(for: mood, limit: Mood.trackCount)
        } catch {
            if error is CancellationError { throw CancellationError() }
            try Task.checkCancellation()
            throw MoodSkipReason.searchFailed(String(describing: error))
        }
        try Task.checkCancellation()
        // An empty result is not a reason to empty the playlist — a sonic index may be rebuilding,
        // or the library may simply have no tagged tracks for this mood. Keep what is there.
        guard !trackIds.isEmpty else { throw MoodSkipReason.noResults }

        let written: Int
        do {
            let playlistId = try await resolvePlaylistId(for: mood, serverId: serverId, client: playlists)
            try Task.checkCancellation()
            // createPlaylist with a non-nil id replaces the whole track list in one call — no
            // read-modify-write, so the playlist is never briefly empty.
            let result = try await playlists.createPlaylist(name: nil, playlistId: playlistId, songIds: trackIds)
            try Task.checkCancellation()
            written = result.songCount
            preferences.setPlaylistId(playlistId, mood: mood, serverId: serverId)
        } catch {
            if error is CancellationError { throw CancellationError() }
            try Task.checkCancellation()
            throw MoodSkipReason.playlistWriteFailed(String(describing: error))
        }

        // Trust what the server says it stored, not what we sent it. A Subsonic server silently
        // drops track ids it does not recognise and still answers 200, so a whole batch of foreign
        // ids yields an empty playlist and a perfectly successful-looking call. Treating that as a
        // failure keeps the previous playlist and retries, instead of reporting a write that only
        // happened on our side.
        guard written > 0 else {
            throw MoodSkipReason.serverStoredNothing(sent: trackIds.count, sample: Array(trackIds.prefix(3)))
        }
        if written < trackIds.count {
            Logger.moodPlaylists.warning("[MOOD-SYNC] \(mood.rawValue, privacy: .public): server kept \(written, privacy: .public) of \(trackIds.count, privacy: .public) ids — the rest were unknown to it")
        }

        try Task.checkCancellation()
        preferences.setSyncedCycle(cycle, mood: mood, serverId: serverId)
        Logger.moodPlaylists.info("[MOOD-SYNC] \(mood.rawValue, privacy: .public) refreshed — server stored \(written, privacy: .public) tracks")

        // Once per playlist, not per refresh: the cover never changes, and re-uploading it every
        // week would be pure waste. Failures are silent — a playlist without its cover still works.
        if let applyCover, !preferences.hasCover(mood: mood, serverId: serverId) {
            let playlistId = preferences.playlistId(mood: mood, serverId: serverId)
            if let playlistId {
                try Task.checkCancellation()
                await applyCover(mood.gradientSpec, playlistId, mood.playlistName)
                try Task.checkCancellation()
                preferences.setHasCover(mood: mood, serverId: serverId)
            }
        }
    }

    /// Cached id, else an existing playlist of the same name, else a newly created one.
    ///
    /// The name lookup matters after a reinstall: UserDefaults is gone but the server playlists are
    /// not, and without it every reinstall would leave a second "Minidisc · Night" behind.
    private func resolvePlaylistId(for mood: Mood, serverId: String, client: any PlaylistSyncClient) async throws -> String {
        try Task.checkCancellation()
        if let cached = preferences.playlistId(mood: mood, serverId: serverId) { return cached }
        let playlists = try await client.getPlaylists(username: nil)
        try Task.checkCancellation()
        if let existing = playlists.first(where: { $0.name == mood.playlistName }) {
            return existing.id
        }
        let created = try await client.createPlaylist(name: mood.playlistName, playlistId: nil, songIds: [])
        try Task.checkCancellation()
        return created.id
    }

    // MARK: - Read

    /// Server playlist id backing a mood, or nil before its first successful sync.
    func playlistId(for mood: Mood, serverId: String) -> String? {
        preferences.playlistId(mood: mood, serverId: serverId)
    }

    func lastRefresh(serverId: String) -> Date? {
        preferences.lastRefresh(serverId: serverId)
    }

    /// Which source last populated the playlists, for the settings screen to be honest about
    /// whether the user is getting sonic matching or tag matching.
    func lastSource(serverId: String) -> MoodSourceKind? {
        preferences.lastSource(serverId: serverId)
    }

    /// Clears local state when the user disconnects AudioMuse. The server playlists are left in
    /// place — they are the user's now, and deleting them would be a surprise.
    func forgetLocalState(serverId: String) {
        preferences.reset(serverId: serverId)
    }
}
