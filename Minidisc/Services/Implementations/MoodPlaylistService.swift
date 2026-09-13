import Foundation
import SwiftSonic
import OSLog

nonisolated protocol MoodPlaylistClient: PlaylistSyncClient {
    func deletePlaylist(id: String) async throws
}

extension SwiftSonicClient: MoodPlaylistClient {}

nonisolated struct MoodPlaylist: Sendable, Equatable, Identifiable {
    let mood: Mood
    let id: String
    let coverArtId: String?
}

nonisolated enum MoodDeletionOutcome: Sendable, Equatable {
    case finished(deleted: Int, failed: Int)
    case inProgress
    case failed
    case cancelled
}

// MARK: - Results

nonisolated enum MoodSyncOutcome: Sendable, Equatable {
    case disabled
    case inProgress
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
    private var isSyncing = false
    private let preferences: MoodPreferences
    private var revision = 0
    private let makePlaylistClient: @Sendable (String) async throws -> (client: any MoodPlaylistClient, owner: String?)
    private let recordMutation: (@Sendable (String, PlaylistWithSongs?, String?) async -> Void)?
    private let makeProvider: @Sendable () async -> (any MoodTrackProvider)?
    /// Renders and applies a playlist cover. Injected rather than called directly because
    /// PlaylistCoverManager is MainActor-bound and this is an actor.
    private let applyCover: (@Sendable (PlaylistGradientSpec, String, String) async -> Void)?

    /// Minimum gap between attempts, so an unreachable instance is not re-probed every launch.
    static let attemptThrottle: TimeInterval = 3600

    init(
        playlistClientFactory: @escaping @Sendable () async throws -> any MoodPlaylistClient,
        playlistOwner: String? = nil,
        providerFactory: @escaping @Sendable () async -> (any MoodTrackProvider)?,
        coverApplier: (@Sendable (PlaylistGradientSpec, String, String) async -> Void)? = nil,
        preferences: MoodPreferences = MoodPreferences()
    ) {
        self.makePlaylistClient = { _ in (try await playlistClientFactory(), playlistOwner) }
        self.recordMutation = nil
        self.makeProvider = providerFactory
        self.applyCover = coverApplier
        self.preferences = preferences
    }

    /// Production wiring. AudioMuse when it is configured and reachable-looking, the server's own
    /// tags otherwise — so the moods exist on every server, just better on some.
    init(
        serverService: any ServerServiceProtocol,
        serverState: ServerState,
        libraryService: any LibrarySearching & MoodTrackSourcing,
        catalog: LibraryCatalog,
        coverApplier: (@Sendable (PlaylistGradientSpec, String, String) async -> Void)? = nil,
        preferences: MoodPreferences = MoodPreferences()
    ) {
        self.preferences = preferences
        self.applyCover = coverApplier
        self.makePlaylistClient = { serverId in
            let connection = try await serverService.activeConnection()
            guard connection.server.id.uuidString == serverId else { throw CancellationError() }
            return (connection.makeSwiftSonicClient(), connection.server.username)
        }
        self.recordMutation = { serverId, detail, deletedID in
            guard await serverService.activeConnectionVersion()?.serverID.uuidString == serverId else { return }
            await catalog.recordPlaylistMutation(summary: nil, detail: detail, deletedID: deletedID)
        }
        self.makeProvider = {
            if let urlString = await MainActor.run(body: { serverState.activeServer?.audioMuseURL }),
               let credentials = try? await serverService.activeConnection().credentials,
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
        try await sync(serverId: serverId, calendar: calendar, currentDate: currentDate, automatic: true, force: false)
    }

    private func sync(
        serverId: String,
        calendar: Calendar,
        currentDate: Date,
        automatic: Bool,
        force: Bool
    ) async throws -> MoodSyncOutcome {
        try Task.checkCancellation()
        guard !automatic || preferences.automaticGenerationEnabled else { return .disabled }
        guard !isSyncing else { return .inProgress }
        isSyncing = true
        revision += 1
        defer { finishOperation(serverId: serverId) }
        if force { preferences.markAllDue(serverId: serverId) }
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
        try checkCanContinue(automatic: automatic)
        guard let provider else { return .notConfigured }

        let playlists: any MoodPlaylistClient
        let owner: String?
        do {
            (playlists, owner) = try await makePlaylistClient(serverId)
        } catch {
            if error is CancellationError { throw CancellationError() }
            try checkCanContinue(automatic: automatic)
            Logger.moodPlaylists.error("[MOOD-SYNC] no Subsonic client: \(error, privacy: .public)")
            preferences.setLastAttempt(currentDate, serverId: serverId)
            return .finished(source: provider.kind, refreshed: [], kept: pending)
        }
        try checkCanContinue(automatic: automatic)

        await provider.prepare()
        try checkCanContinue(automatic: automatic)

        var refreshed: [Mood] = []
        var kept: [Mood] = []
        for mood in pending {
            try checkCanContinue(automatic: automatic)
            do {
                try await refresh(mood, serverId: serverId, cycle: cycle, provider: provider, playlists: playlists, owner: owner, automatic: automatic)
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

        try checkCanContinue(automatic: automatic)
        Logger.moodPlaylists.info("[MOOD-SYNC] source=\(provider.kind.rawValue, privacy: .public) refreshed \(refreshed.count, privacy: .public)/\(pending.count, privacy: .public) — kept \(kept.map(\.rawValue).joined(separator: ","), privacy: .public)")
        preferences.setLastAttempt(currentDate, serverId: serverId)
        preferences.setLastSource(provider.kind, serverId: serverId)
        return .finished(source: provider.kind, refreshed: refreshed, kept: kept)
    }

    /// Manual regeneration also works when automatic generation is disabled.
    /// Playlist ids are kept, so existing playlists are rewritten in place.
    @discardableResult
    func rebuildNow(serverId: String, calendar: Calendar = .current, currentDate: Date = Date()) async -> MoodSyncOutcome {
        await rebuild(serverId: serverId, calendar: calendar, currentDate: currentDate, automatic: false)
    }

    /// Connecting or disconnecting AudioMuse respects the automatic generation preference.
    @discardableResult
    func rebuildAfterSourceChange(serverId: String) async -> MoodSyncOutcome {
        await rebuild(serverId: serverId, calendar: .current, currentDate: Date(), automatic: true)
    }

    private func rebuild(serverId: String, calendar: Calendar, currentDate: Date, automatic: Bool) async -> MoodSyncOutcome {
        do {
            return try await sync(serverId: serverId, calendar: calendar, currentDate: currentDate, automatic: automatic, force: true)
        } catch {
            return .cancelled
        }
    }

    private func checkCanContinue(automatic: Bool) throws {
        try Task.checkCancellation()
        // Do not start another server mutation after automatic generation has been switched off.
        if automatic && !preferences.automaticGenerationEnabled { throw CancellationError() }
    }

    /// One mood, end to end. Throws `MoodSkipReason` so the caller can keep going; the marker is
    /// only advanced once the server has accepted the new track list.
    private func refresh(
        _ mood: Mood,
        serverId: String,
        cycle: Date,
        provider: any MoodTrackProvider,
        playlists: any PlaylistSyncClient,
        owner: String?,
        automatic: Bool
    ) async throws {
        try checkCanContinue(automatic: automatic)
        let trackIds: [String]
        do {
            trackIds = try await provider.trackIds(for: mood, limit: Mood.trackCount)
        } catch {
            if error is CancellationError { throw CancellationError() }
            try checkCanContinue(automatic: automatic)
            throw MoodSkipReason.searchFailed(String(describing: error))
        }
        try checkCanContinue(automatic: automatic)
        // An empty result is not a reason to empty the playlist — a sonic index may be rebuilding,
        // or the library may simply have no tagged tracks for this mood. Keep what is there.
        guard !trackIds.isEmpty else { throw MoodSkipReason.noResults }

        let written: Int
        do {
            let playlistId = try await resolvePlaylistId(for: mood, serverId: serverId, client: playlists, owner: owner, automatic: automatic)
            try checkCanContinue(automatic: automatic)
            // createPlaylist with a non-nil id replaces the whole track list in one call — no
            // read-modify-write, so the playlist is never briefly empty.
            let result = try await playlists.createPlaylist(name: nil, playlistId: playlistId, songIds: trackIds)
            try checkCanContinue(automatic: automatic)
            written = result.songCount
            preferences.setPlaylistId(result.id, mood: mood, serverId: serverId)
            await recordMutation?(serverId, result, nil)
        } catch {
            if error is CancellationError { throw CancellationError() }
            try checkCanContinue(automatic: automatic)
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

        try checkCanContinue(automatic: automatic)
        preferences.setSyncedCycle(cycle, mood: mood, serverId: serverId)
        Logger.moodPlaylists.info("[MOOD-SYNC] \(mood.rawValue, privacy: .public) refreshed — server stored \(written, privacy: .public) tracks")

        // Once per playlist, not per refresh: the cover never changes, and re-uploading it every
        // week would be pure waste. Failures are silent — a playlist without its cover still works.
        if let applyCover, !preferences.hasCover(mood: mood, serverId: serverId) {
            let playlistId = preferences.playlistId(mood: mood, serverId: serverId)
            if let playlistId {
                try checkCanContinue(automatic: automatic)
                await applyCover(mood.gradientSpec, playlistId, mood.playlistName)
                try checkCanContinue(automatic: automatic)
                preferences.setHasCover(mood: mood, serverId: serverId)
            }
        }
    }

    /// Validate the remembered id against the server before replacing any tracks.
    ///
    /// The name lookup matters after a reinstall: UserDefaults is gone but the server playlists are
    /// not, and without it every reinstall would leave a second "Minidisc · Night" behind.
    private func resolvePlaylistId(for mood: Mood, serverId: String, client: any PlaylistSyncClient, owner: String?, automatic: Bool) async throws -> String {
        try checkCanContinue(automatic: automatic)
        let playlists = try await client.getPlaylists(username: nil)
        try checkCanContinue(automatic: automatic)
        if let existing = matchingPlaylist(mood, in: playlists, serverId: serverId, owner: owner) {
            preferences.setPlaylistId(existing.id, mood: mood, serverId: serverId)
            return existing.id
        }
        let created = try await client.createPlaylist(name: mood.playlistName, playlistId: nil, songIds: [])
        try checkCanContinue(automatic: automatic)
        preferences.setPlaylistId(created.id, mood: mood, serverId: serverId)
        return created.id
    }

    private func matchingPlaylist(_ mood: Mood, in playlists: [Playlist], serverId: String, owner: String?) -> Playlist? {
        let candidates = playlists.filter {
            $0.name == mood.playlistName && (owner == nil || $0.owner == nil || $0.owner == owner)
        }
        let cached = preferences.playlistId(mood: mood, serverId: serverId)
        return candidates.first(where: { $0.id == cached }) ?? candidates.sorted { $0.id < $1.id }.first
    }

    /// Discovery is independent of generation: even with automation off, recover playlists
    /// created on another install and replace stale ids. A failed request never clears local state.
    func fetchPlaylists(serverId: String) async throws -> [MoodPlaylist] {
        guard !isSyncing else { throw CancellationError() }
        let readRevision = revision
        let (client, owner) = try await makePlaylistClient(serverId)
        let playlists = try await client.getPlaylists(username: nil)
        try Task.checkCancellation()
        guard !isSyncing, revision == readRevision else { throw CancellationError() }
        return reconcile(playlists, serverId: serverId, owner: owner)
    }

    func cachedPlaylists(serverId: String) -> [MoodPlaylist] {
        Mood.allCases.compactMap { mood in
            guard let id = preferences.playlistId(mood: mood, serverId: serverId) else { return nil }
            return MoodPlaylist(mood: mood, id: id, coverArtId: nil)
        }
    }

    private func reconcile(_ playlists: [Playlist], serverId: String, owner: String?) -> [MoodPlaylist] {
        Mood.allCases.compactMap { mood in
            guard let playlist = matchingPlaylist(mood, in: playlists, serverId: serverId, owner: owner) else {
                preferences.clearPlaylist(mood: mood, serverId: serverId)
                return nil
            }
            preferences.setPlaylistId(playlist.id, mood: mood, serverId: serverId)
            return MoodPlaylist(mood: mood, id: playlist.id, coverArtId: playlist.coverArt)
        }
    }

    /// Removes only this user's canonical mood playlists. Other playlists and downloaded
    /// audio are kept. Automatic generation is turned off so removal is durable.
    func deletePlaylists(serverId: String) async -> MoodDeletionOutcome {
        guard !Task.isCancelled else { return .cancelled }
        guard !isSyncing else { return .inProgress }
        isSyncing = true
        revision += 1
        defer { finishOperation(serverId: serverId) }
        preferences.automaticGenerationEnabled = false
        do {
            let (client, owner) = try await makePlaylistClient(serverId)
            let playlists = try await client.getPlaylists(username: nil)
            try Task.checkCancellation()
            _ = reconcile(playlists, serverId: serverId, owner: owner)
            let names = Set(Mood.allCases.map(\.playlistName))
            var remaining = playlists
            var deleted = 0
            var failed = 0
            for playlist in playlists where names.contains(playlist.name)
                && (owner == nil || playlist.owner == nil || playlist.owner == owner) {
                try Task.checkCancellation()
                do {
                    do { try await client.deletePlaylist(id: playlist.id) }
                    catch let error as SwiftSonicError {
                        switch error {
                        case .api(let apiError) where apiError.code == .notFound: break
                        case .httpError(let code, _, _) where code == 404: break
                        default: throw error
                        }
                    }
                    // Persist each confirmed deletion even if the next request is cancelled.
                    remaining.removeAll { $0.id == playlist.id }
                    _ = reconcile(remaining, serverId: serverId, owner: owner)
                    deleted += 1
                    await recordMutation?(serverId, nil, playlist.id)
                } catch is CancellationError { throw CancellationError() }
                catch { failed += 1 }
            }
            if failed == 0 { preferences.reset(serverId: serverId) }
            return .finished(deleted: deleted, failed: failed)
        } catch is CancellationError { return .cancelled }
        catch { return .failed }
    }

    private func finishOperation(serverId: String) {
        isSyncing = false
        revision += 1
        Task { @MainActor in
            NotificationCenter.default.post(name: .minidiscMoodPlaylistsChanged, object: serverId)
        }
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
