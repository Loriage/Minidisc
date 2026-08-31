import Foundation
import SwiftData
import SwiftSonic
import OSLog

actor LibraryService: LibraryServiceProtocol {
    private let serverService: any ServerServiceProtocol
    private let modelContainer: ModelContainer
    private let downloadService: any DownloadServiceProtocol
    private let statsService: StatsService
    private let catalog: LibraryCatalog
    private let indexStore: LibraryIndexStore
    private var cachedClient: SwiftSonicClient?
    private var cachedConnectionVersion: ServerConnection.Version?
    private var artistInfoCache: [String: ArtistInfo] = [:]

    init(
        serverService: any ServerServiceProtocol,
        modelContainer: ModelContainer,
        downloadService: any DownloadServiceProtocol,
        statsService: StatsService,
        catalog: LibraryCatalog,
        indexStore: LibraryIndexStore
    ) {
        self.serverService = serverService
        self.modelContainer = modelContainer
        self.downloadService = downloadService
        self.statsService = statsService
        self.catalog = catalog
        self.indexStore = indexStore
    }

    private func client() async throws -> SwiftSonicClient {
        // ServerService owns the version on its actor, so this cache check never waits on MainActor.
        let activeVersion = await serverService.activeConnectionVersion()
        if let cached = cachedClient,
           let activeVersion,
           cachedConnectionVersion == activeVersion {
            Logger.library.debug("[CLIENT] cache hit")
            return cached
        }
        Logger.library.debug("[CLIENT] cache miss → activeConnection")
        let connection = try await serverService.activeConnection()
        let fresh = connection.makeSwiftSonicClient()
        Logger.library.debug("[CLIENT] ← activeConnection done")
        cachedClient = fresh
        cachedConnectionVersion = connection.version
        artistInfoCache = [:]
        return fresh
    }

    func artists() async throws -> [ArtistIndex] {
        try await catalog.artists()
    }

    func artist(id: String) async throws -> ArtistID3 {
        Logger.library.debug("[ARTIST] artist(id:) START id=\(id, privacy: .public)")
        Logger.library.debug("[ARTIST] → catalogue")
        let t0 = Date()
        let result = try await catalog.artist(id: id)
        let elapsed = String(format: "%.2f", Date().timeIntervalSince(t0))
        Logger.library.debug("[ARTIST] ← catalogue done \(elapsed, privacy: .public)s")
        return result
    }

    func album(id: String) async throws -> AlbumID3 {
        try await catalog.album(id: id)
    }

    func playlists() async throws -> [Playlist] {
        try await client().getPlaylists()
    }

    func playlist(id: String) async throws -> PlaylistWithSongs {
        try await client().getPlaylist(id: id)
    }

    func search(_ query: String) async throws -> SearchResult3 {
        try await catalog.search(query)
    }

    func coverArtURL(id: String, size: Int?) async -> URL? {
        guard let c = try? await client() else { return nil }
        return c.coverArtURL(id: id, size: size)
    }

    func streamURL(songId: String) async -> URL? {
        guard let c = try? await client() else { return nil }
        return c.streamURL(id: songId)
    }

    func star(songIds: [String], albumIds: [String], artistIds: [String]) async throws {
        try await client().star(songIds: songIds, albumIds: albumIds, artistIds: artistIds)
    }

    func unstar(songIds: [String], albumIds: [String], artistIds: [String]) async throws {
        try await client().unstar(songIds: songIds, albumIds: albumIds, artistIds: artistIds)
    }

    func getStarred2() async throws -> Starred2 {
        try await client().getStarred2()
    }

    func recentlyAddedAlbums(size: Int) async throws -> [AlbumID3] {
        try await catalog.recentlyAddedAlbums(size: size)
    }

    func allAlbums() async throws -> [AlbumID3] {
        try await catalog.albums()
    }

    func allSongs(offset: Int, count: Int) async throws -> [Song] {
        try await catalog.songs(offset: offset, count: count)
    }

    // MARK: - Artist tracks

    func fetchAllTracks(forArtistID artistID: String) async throws -> [DisplayableSong] {
        try Task.checkCancellation()
        do {
            if let indexedSongs = try await catalog.songs(artistID: artistID) {
                let serverID = await MainActor.run { serverService.state.activeServer?.id }
                let downloadedIDs = if let serverID {
                    await downloadService.downloadedSongIds(serverId: serverID)
                } else {
                    Set<String>()
                }
                try Task.checkCancellation()
                return indexedSongs.map {
                    DisplayableSong(from: $0, isDownloaded: downloadedIDs.contains($0.id))
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Logger.library.debug(
                "[ARTIST-TRACKS] local index unavailable, falling back to server: \(error, privacy: .public)"
            )
        }

        let artistDetail = try await artist(id: artistID)
        try Task.checkCancellation()
        let albums = (artistDetail.album ?? []).sorted { lhs, rhs in
            switch (lhs.year, rhs.year) {
            case let (y1?, y2?): return y1 > y2
            case (_?, nil):      return true
            case (nil, _?):      return false
            case (nil, nil):     return lhs.name < rhs.name
            }
        }
        guard !albums.isEmpty else { return [] }

        var collected: [(index: Int, songs: [DisplayableSong])] = []

        try await withThrowingTaskGroup(of: (Int, [DisplayableSong]?).self) { group in
            defer { group.cancelAll() }
            var submitted = 0

            while submitted < min(5, albums.count) {
                try Task.checkCancellation()
                let i = submitted
                let albumId = albums[i].id
                group.addTask {
                    try await self.fetchAlbumTracks(albumId: albumId, index: i)
                }
                submitted += 1
            }

            while let (index, songs) = try await group.next() {
                try Task.checkCancellation()
                if let songs { collected.append((index, songs)) }
                if submitted < albums.count {
                    let i = submitted
                    let albumId = albums[i].id
                    group.addTask {
                        try await self.fetchAlbumTracks(albumId: albumId, index: i)
                    }
                    submitted += 1
                }
            }
        }
        try Task.checkCancellation()

        guard !collected.isEmpty else {
            Logger.library.error("[ARTIST-TRACKS] all fetches failed artistId=\(artistID, privacy: .public)")
            throw MinidiscError.artistTracksUnavailable
        }

        Logger.library.debug("[ARTIST-TRACKS] fetched \(collected.count)/\(albums.count) albums artistId=\(artistID, privacy: .public)")
        return collected.sorted { $0.index < $1.index }.flatMap { $0.songs }
    }

    private func fetchAlbumTracks(albumId: String, index: Int) async throws -> (Int, [DisplayableSong]?) {
        try Task.checkCancellation()
        do {
            let detail = try await album(id: albumId)
            try Task.checkCancellation()
            let serverId = await MainActor.run { serverService.state.activeServer?.id }
            try Task.checkCancellation()
            var songs: [DisplayableSong] = []
            for song in detail.song ?? [] {
                try Task.checkCancellation()
                var downloaded = false
                if let serverId {
                    downloaded = await downloadService.isDownloaded(songId: song.id, serverId: serverId)
                    try Task.checkCancellation()
                }
                songs.append(DisplayableSong(from: song, isDownloaded: downloaded))
            }
            return (index, songs)
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            try Task.checkCancellation()
            Logger.library.error("[ARTIST-TRACKS] album \(albumId) fetch failed: \(error, privacy: .public)")
            return (index, nil)
        }
    }

    // MARK: - Discover

    func scrobble(songId: String, submission: Bool) async {
        do {
            try Task.checkCancellation()
            let subsonicClient = try await client()
            try Task.checkCancellation()
            try await subsonicClient.scrobble(id: songId, submission: submission)
            try Task.checkCancellation()
            Logger.library.debug("Scrobbled '\(songId, privacy: .public)' submission=\(submission)")
        } catch is CancellationError {
            Logger.library.debug(
                "Scrobble cancelled for '\(songId, privacy: .public)' submission=\(submission)"
            )
        } catch {
            // Silent failure per Subsonic convention. Log at debug level only — scrobble errors
            // are common (network blips, auth races) and should never surface to the user.
            Logger.library.debug("Scrobble failed for '\(songId, privacy: .public)' submission=\(submission): \(error, privacy: .public)")
        }
    }

    func recentlyPlayedAlbums(size: Int) async throws -> [AlbumID3] {
        try await client().getAlbumList2(type: .recent, size: size)
    }

    func mostPlayedAlbums(size: Int) async throws -> [AlbumID3] {
        try await client().getAlbumList2(type: .frequent, size: size)
    }

    func songsByGenre(_ genre: String, count: Int) async throws -> [Song] {
        try await client().getSongsByGenre(genre, count: count)
    }

    func genres() async throws -> [Genre] {
        try await client().getGenres()
    }

    func albumsByGenre(_ genre: String, size: Int) async throws -> [AlbumID3] {
        try await client().getAlbumList2(type: .byGenre, size: size, genre: genre)
    }

    func randomSongs(size: Int) async throws -> [Song] {
        try await client().getRandomSongs(size: size)
    }

    func smartShuffleQueue(targetSize: Int) async throws -> [DisplayableSong] {
        let isOnline = await MainActor.run { serverService.state.isOnline }
        if isOnline {
            return try await onlineSmartShuffle(targetSize: targetSize)
        } else {
            return await offlineSmartShuffle(targetSize: targetSize)
        }
    }

    private func onlineSmartShuffle(targetSize: Int) async throws -> [DisplayableSong] {
        // Product rule: rediscover is TRULY random — no recency weighting,
        // no `played` filtering. The server picks uniformly across the library.
        let songs = try await client().getRandomSongs(size: targetSize)
        Logger.library.debug("Smart shuffle online: \(songs.count) random tracks (target \(targetSize))")
        return songs.map { DisplayableSong(from: $0) }
    }

    // MARK: - Auto-extend similar backfill

    /// Most recent distinct seed values win; bounds keep the candidate fan-out cheap
    /// (each artist seed costs one discography fetch, each genre one getSongsByGenre).
    nonisolated static let backfillMaxSeedArtists = 5
    nonisolated static let backfillMaxSeedGenres = 3
    nonisolated static let backfillGenreFetchCount = 100

    /// Extracts distinct artist ids and genres from recent plays, newest first.
    nonisolated static func similaritySeeds(
        from events: [PlaybackEventDTO],
        maxArtists: Int = backfillMaxSeedArtists,
        maxGenres: Int = backfillMaxSeedGenres
    ) -> (artistIds: [String], genres: [String]) {
        var artistIds: [String] = []
        var genres: [String] = []
        for event in events {
            if let id = event.artistId, !id.isEmpty, artistIds.count < maxArtists, !artistIds.contains(id) {
                artistIds.append(id)
            }
            if let genre = event.genre, !genre.isEmpty, genres.count < maxGenres, !genres.contains(genre) {
                genres.append(genre)
            }
        }
        return (artistIds, genres)
    }

    /// Shuffles the candidate pool, drops excluded and duplicate ids, and caps at
    /// `targetSize`. Pure — the network-facing caller assembles the inputs.
    nonisolated static func assembleBackfill(
        pool: [DisplayableSong],
        excludedIds: Set<String>,
        targetSize: Int
    ) -> [DisplayableSong] {
        var seen = excludedIds
        var result: [DisplayableSong] = []
        for song in pool.shuffled() where !seen.contains(song.id) {
            seen.insert(song.id)
            result.append(song)
            if result.count == targetSize { break }
        }
        return result
    }

    func similarBackfillQueue(targetSize: Int, excludedIds: Set<String>) async throws -> [DisplayableSong] {
        try Task.checkCancellation()
        let isOnline = await MainActor.run { serverService.state.isOnline }
        try Task.checkCancellation()
        guard isOnline else {
            // Offline: keep the downloads-only fallback, still honoring exclusions.
            let downloads = await offlineSmartShuffle(targetSize: targetSize + excludedIds.count)
            try Task.checkCancellation()
            return Self.assembleBackfill(pool: downloads, excludedIds: excludedIds, targetSize: targetSize)
        }
        guard let serverId = await MainActor.run(body: { serverService.state.activeServer?.id }) else {
            return []
        }
        try Task.checkCancellation()

        let recent = await statsService.recentEvents(limit: 20, serverId: serverId.uuidString)
        try Task.checkCancellation()
        // Never re-serve what the user just heard.
        var excluded = excludedIds
        for event in recent { excluded.insert(event.trackId) }

        // No ≥30s listening history yet → degrade to pure random.
        let seeds = Self.similaritySeeds(from: recent)
        var pool: [DisplayableSong] = []
        if !recent.isEmpty {
            // Artist candidates: full discographies via the existing bounded fetcher.
            // Deliberately NOT getTopSongs — popularity-backed per spec, empty on bare
            // self-hosted servers; kept out so the heuristic works everywhere.
            for artistId in seeds.artistIds {
                try Task.checkCancellation()
                do {
                    let tracks = try await fetchAllTracks(forArtistID: artistId)
                    pool.append(contentsOf: tracks)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Best-effort: another seed or the random top-up can still fill the queue.
                }
            }
            // Genre candidates from local tags.
            for genre in seeds.genres {
                try Task.checkCancellation()
                do {
                    let songs = try await client().getSongsByGenre(
                        genre,
                        count: Self.backfillGenreFetchCount
                    )
                    try Task.checkCancellation()
                    pool.append(contentsOf: songs.map { DisplayableSong(from: $0) })
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Best-effort: another seed or the random top-up can still fill the queue.
                }
            }
        }

        var result = Self.assembleBackfill(pool: pool, excludedIds: excluded, targetSize: targetSize)

        // Thin pool (small library, empty genres) or no history: top up with random.
        if result.count < targetSize {
            let randomSongs: [Song]
            do {
                randomSongs = try await client().getRandomSongs(size: targetSize + excluded.count)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                randomSongs = []
            }
            try Task.checkCancellation()
            excluded.formUnion(result.map(\.id))
            let topUp = Self.assembleBackfill(
                pool: randomSongs.map { DisplayableSong(from: $0) },
                excludedIds: excluded,
                targetSize: targetSize - result.count
            )
            result.append(contentsOf: topUp)
        }

        Logger.library.debug("Similar backfill: \(result.count)/\(targetSize) tracks (seeds: \(seeds.artistIds.count) artists, \(seeds.genres.count) genres, recent: \(recent.count))")
        try Task.checkCancellation()
        return result
    }

    // MARK: - Recommendations

    nonisolated static let albumRecommendationCacheLifetime: TimeInterval = 7 * 24 * 60 * 60

    func similarAlbums(
        to albumID: String,
        excludingArtistID artistID: String?,
        excludingArtistName artistName: String?,
        limit: Int
    ) async throws -> [AlbumID3] {
        guard limit > 0 else { return [] }
        try Task.checkCancellation()

        if let serverID = await serverService.activeConnectionVersion()?.serverID {
            do {
                if let cached = try await indexStore.albumRecommendations(
                    sourceAlbumID: albumID,
                    serverID: serverID
                ) {
                    let result = Array(cached.albums.prefix(limit))
                    if cached.isFresh(at: .now, lifetime: Self.albumRecommendationCacheLifetime),
                       cached.canSatisfy(limit: limit) {
                        return result
                    }

                    // A stale result is still preferable to a section that appears after the user
                    // reaches the bottom of the page. Refresh it for the next visit without mutating
                    // the current screen out from under the user.
                    Task(priority: .utility) { [weak self] in
                        guard let self else { return }
                        do {
                            _ = try await self.refreshAlbumRecommendations(
                                to: albumID,
                                excludingArtistID: artistID,
                                excludingArtistName: artistName,
                                limit: limit,
                                serverID: serverID
                            )
                        } catch is CancellationError {
                            return
                        } catch {
                            Logger.library.debug(
                                "Album recommendation refresh failed for \(albumID, privacy: .public): \(error, privacy: .public)"
                            )
                        }
                    }
                    return result
                }
            } catch {
                Logger.library.debug(
                    "Album recommendation cache read failed for \(albumID, privacy: .public): \(error, privacy: .public)"
                )
            }

            return try await refreshAlbumRecommendations(
                to: albumID,
                excludingArtistID: artistID,
                excludingArtistName: artistName,
                limit: limit,
                serverID: serverID
            )
        }

        return try await fetchAlbumRecommendations(
            to: albumID,
            excludingArtistID: artistID,
            excludingArtistName: artistName,
            limit: limit
        )
    }

    /// Forces a server refresh and persists even an empty result. The maintenance service uses
    /// this concrete operation while walking every album in the dedicated SwiftData index.
    func refreshAlbumRecommendations(
        to albumID: String,
        excludingArtistID artistID: String?,
        excludingArtistName artistName: String?,
        limit: Int,
        serverID: UUID
    ) async throws -> [AlbumID3] {
        guard limit > 0 else { return [] }
        let activeServerID = await serverService.activeConnectionVersion()?.serverID
        guard activeServerID == serverID else { throw MinidiscError.serverNotConfigured }

        let recommendations = try await fetchAlbumRecommendations(
            to: albumID,
            excludingArtistID: artistID,
            excludingArtistName: artistName,
            limit: limit
        )
        try Task.checkCancellation()
        try await indexStore.cacheAlbumRecommendations(
            recommendations,
            sourceAlbumID: albumID,
            serverID: serverID,
            requestedLimit: limit
        )
        return recommendations
    }

    private func fetchAlbumRecommendations(
        to albumID: String,
        excludingArtistID artistID: String?,
        excludingArtistName artistName: String?,
        limit: Int
    ) async throws -> [AlbumID3] {
        guard limit > 0 else { return [] }
        try Task.checkCancellation()

        let subsonicClient = try await client()
        let requestCount = min(max(limit * 5, 50), 200)
        var matches: [Song]
        var usedArtistFallback = false

        do {
            matches = try await subsonicClient.getSimilarSongs(id: albumID, count: requestCount)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard let artistID else { throw error }
            Logger.library.debug(
                "Album similarity failed for album \(albumID, privacy: .public); falling back to artist similarity: \(error, privacy: .public)"
            )
            matches = try await subsonicClient.getSimilarSongs2(id: artistID, count: requestCount)
            usedArtistFallback = true
        }

        try Task.checkCancellation()
        var recommendations = Self.albumRecommendations(
            from: matches,
            excludingAlbumID: albumID,
            excludingArtistID: artistID,
            excludingArtistName: artistName,
            limit: limit
        )

        // A valid album result is immediately useful and must not wait on a second server round trip.
        // Artist similarity remains a rescue path for servers that cannot resolve an album seed at all.
        if recommendations.isEmpty, let artistID, !usedArtistFallback {
            do {
                let artistMatches = try await subsonicClient.getSimilarSongs2(
                    id: artistID,
                    count: requestCount
                )
                try Task.checkCancellation()
                matches.append(contentsOf: artistMatches)
                recommendations = Self.albumRecommendations(
                    from: matches,
                    excludingAlbumID: albumID,
                    excludingArtistID: artistID,
                    excludingArtistName: artistName,
                    limit: limit
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Logger.library.debug(
                    "Artist similarity backfill failed for album \(albumID, privacy: .public): \(error, privacy: .public)"
                )
            }
        }

        return recommendations
    }

    /// Converts a ranked similar-song response into stable, diverse album cards without another network round trip.
    /// Multiple matching tracks strengthen an album while first-seen order breaks ties, preserving server relevance.
    nonisolated static func albumRecommendations(
        from songs: [Song],
        excludingAlbumID: String,
        excludingArtistID: String?,
        excludingArtistName: String?,
        limit: Int
    ) -> [AlbumID3] {
        guard limit > 0 else { return [] }

        let normalizedExcludedArtistName = excludingArtistName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        var grouped: [String: (song: Song, count: Int, firstIndex: Int)] = [:]

        for (index, song) in songs.enumerated() {
            guard let candidateAlbumID = song.albumId,
                  candidateAlbumID != excludingAlbumID,
                  let albumName = song.album?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !albumName.isEmpty else {
                continue
            }

            if let excludingArtistID, song.artistId == excludingArtistID {
                continue
            }
            if let normalizedExcludedArtistName,
               song.artist?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                   == normalizedExcludedArtistName {
                continue
            }

            if var existing = grouped[candidateAlbumID] {
                existing.count += 1
                grouped[candidateAlbumID] = existing
            } else {
                grouped[candidateAlbumID] = (song, 1, index)
            }
        }

        let ranked = grouped.values.sorted { lhs, rhs in
            if lhs.count != rhs.count {
                return lhs.count > rhs.count
            }
            return lhs.firstIndex < rhs.firstIndex
        }

        var albums: [AlbumID3] = []
        var artistCounts: [String: Int] = [:]
        albums.reserveCapacity(min(limit, ranked.count))

        for candidate in ranked {
            guard let candidateAlbumID = candidate.song.albumId,
                  let albumName = candidate.song.album?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !albumName.isEmpty else {
                continue
            }

            let artistKey = candidate.song.artistId
                ?? candidate.song.artist?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                ?? candidateAlbumID
            guard artistCounts[artistKey, default: 0] < 2 else { continue }

            albums.append(
                AlbumID3(
                    id: candidateAlbumID,
                    name: albumName,
                    songCount: 0,
                    duration: 0,
                    artist: candidate.song.artist,
                    artistId: candidate.song.artistId,
                    coverArt: candidate.song.coverArt,
                    year: candidate.song.year,
                    genre: candidate.song.genre
                )
            )
            artistCounts[artistKey, default: 0] += 1

            if albums.count == limit { break }
        }

        return albums
    }

    func topSongs(artist: String, count: Int) async throws -> [DisplayableSong] {
        try await client().getTopSongs(artist: artist, count: count).map { DisplayableSong(from: $0) }
    }

    func instantMix(from seed: InstantMixSeed, count: Int) async throws -> [DisplayableSong] {
        // Timing is logged at .info, on one line, because this is the latency the user actually feels:
        // nothing plays until the whole fan-out returns. The per-call spread of the fan-out is what
        // says whether the client-side parallelism survives on the server or re-serialises there.
        try Task.checkCancellation()
        let tStart = Date()
        let c = try await client()
        try Task.checkCancellation()

        // 1) Base similar songs from the seed. AudioMuse clusters tightly, so this alone tends to
        //    cover only one or two artists.
        let tBase = Date()
        let base: [Song]
        switch seed {
        case .song(let id), .album(let id):
            base = try await c.getSimilarSongs(id: id, count: count)
        case .artist(let id):
            base = try await c.getSimilarSongs2(id: id, count: count)
        }
        try Task.checkCancellation()
        let baseMs = Int(Date().timeIntervalSince(tBase) * 1000)
        guard !base.isEmpty else {
            Logger.library.info("[MIX-TIMING] base=\(baseMs, privacy: .public)ms → empty, aborting")
            return []
        }

        // 2) Fan out on the distinct artists we found (plus the seed artist) to broaden the pool —
        //    each getSimilarSongs2 pulls the neighbourhood around a different artist.
        var fanArtists: [String] = []
        var seenArtists = Set<String>()
        if case .artist(let id) = seed, seenArtists.insert(id).inserted { fanArtists.append(id) }
        for song in base {
            guard let aid = song.artistId, seenArtists.insert(aid).inserted else { continue }
            fanArtists.append(aid)
        }
        fanArtists = Array(fanArtists.prefix(Self.instantMixFanOutArtists))

        let tFan = Date()
        var expansions: [Song] = []
        var callMs: [Int] = []
        try await withThrowingTaskGroup(of: (Int, [Song]).self) { group in
            defer { group.cancelAll() }
            for aid in fanArtists {
                try Task.checkCancellation()
                group.addTask {
                    try Task.checkCancellation()
                    let t = Date()
                    do {
                        let songs = try await c.getSimilarSongs2(
                            id: aid,
                            count: Self.instantMixFanOutCount
                        )
                        try Task.checkCancellation()
                        return (Int(Date().timeIntervalSince(t) * 1000), songs)
                    } catch let cancellation as CancellationError {
                        throw cancellation
                    } catch {
                        try Task.checkCancellation()
                        return (Int(Date().timeIntervalSince(t) * 1000), [])
                    }
                }
            }
            for try await (ms, songs) in group {
                try Task.checkCancellation()
                callMs.append(ms)
                expansions.append(contentsOf: songs)
            }
        }
        try Task.checkCancellation()
        let fanMs = Int(Date().timeIntervalSince(tFan) * 1000)

        // 3) Merge + dedup by song id (base first so seed relevance leads).
        var seenIds = Set<String>()
        let merged = (base + expansions).filter { seenIds.insert($0.id).inserted }

        // 4) Round-robin by artist so different artists surface early and none dominates.
        let diversified = Self.diversifyByArtist(merged, maxPerArtist: Self.instantMixMaxPerArtist)
        let distinctArtists = Set(diversified.prefix(count).compactMap { $0.artistId ?? $0.artist }).count
        let totalMs = Int(Date().timeIntervalSince(tStart) * 1000)
        // fanSum vs fanMs is the decisive comparison: close to fanMs means the calls really ran
        // concurrently; close to their sum means the server handled them one at a time.
        let sorted = callMs.sorted()
        let fanSum = callMs.reduce(0, +)
        Logger.library.info("""
            [MIX-TIMING] total=\(totalMs, privacy: .public)ms \
            base=\(baseMs, privacy: .public)ms(\(base.count, privacy: .public) tracks) \
            fanout=\(fanMs, privacy: .public)ms(\(fanArtists.count, privacy: .public) calls, \
            sum=\(fanSum, privacy: .public)ms, min=\(sorted.first ?? 0, privacy: .public) \
            med=\(sorted.isEmpty ? 0 : sorted[sorted.count / 2], privacy: .public) \
            max=\(sorted.last ?? 0, privacy: .public)) \
            → \(diversified.count, privacy: .public) tracks / \(distinctArtists, privacy: .public) artists, \
            kept \(min(count, diversified.count), privacy: .public)
            """)
        return diversified.prefix(count).map { DisplayableSong(from: $0) }
    }

    /// Fan-out tuning for Instant Mix diversity. `nonisolated` so the actor's `instantMix` can read them
    /// synchronously (the module defaults types to MainActor isolation).
    nonisolated private static let instantMixFanOutArtists = 8
    nonisolated private static let instantMixFanOutCount = 25
    nonisolated private static let instantMixMaxPerArtist = 4

    /// Interleaves songs so consecutive tracks come from different artists (round-robin over per-artist
    /// buckets, capped at `maxPerArtist`). Preserves each artist's first-seen relevance order. Pure and
    /// `nonisolated` — callable from the actor without hopping to the main actor.
    nonisolated private static func diversifyByArtist(_ songs: [Song], maxPerArtist: Int) -> [Song] {
        var buckets: [String: [Song]] = [:]
        var artistOrder: [String] = []
        for song in songs {
            let key = song.artistId ?? song.artist ?? song.id
            if buckets[key] == nil { artistOrder.append(key) }
            buckets[key, default: []].append(song)
        }
        var result: [Song] = []
        var taken: [String: Int] = [:]
        var progressed = true
        while progressed {
            progressed = false
            for key in artistOrder {
                let n = taken[key] ?? 0
                guard n < maxPerArtist, let bucket = buckets[key], n < bucket.count else { continue }
                result.append(bucket[n])
                taken[key] = n + 1
                progressed = true
            }
        }
        return result
    }

    func getArtistInfo(forArtistID artistID: String, count: Int) async throws -> ArtistInfo {
        if let cached = artistInfoCache[artistID] {
            Logger.library.debug("[ARTIST-INFO] cache hit artistId=\(artistID, privacy: .public) similarCount=\(cached.similarArtist?.count ?? 0, privacy: .public)")
            return cached
        }
        Logger.library.debug("[ARTIST-INFO] cache miss — network call artistId=\(artistID, privacy: .public) count=\(count, privacy: .public)")
        let started = Date()
        do {
            let info = try await client().getArtistInfo2(id: artistID, count: count)
            let elapsed = Date().timeIntervalSince(started)
            Logger.library.debug("[ARTIST-INFO] success artistId=\(artistID, privacy: .public) \(String(format: "%.2f", elapsed), privacy: .public)s similarCount=\(info.similarArtist?.count ?? 0, privacy: .public)")
            artistInfoCache[artistID] = info
            return info
        } catch {
            let elapsed = Date().timeIntervalSince(started)
            Logger.library.warning("[ARTIST-INFO] FAILED after \(String(format: "%.2f", elapsed), privacy: .public)s artistId=\(artistID, privacy: .public): \(error, privacy: .public)")
            throw error
        }
    }

    func getArtistMBID(forArtistID artistID: String) async throws -> String? {
        try await getArtistInfo(forArtistID: artistID, count: 20).musicBrainzId
    }

    func findArtist(byName name: String) async -> ArtistID3? {
        if let found = await catalog.findArtist(byName: name) {
            Logger.library.debug("[FIND-ARTIST] FOUND '\(name, privacy: .public)' → id=\(found.id, privacy: .public)")
            return found
        }
        Logger.library.debug("[FIND-ARTIST] NOT FOUND '\(name, privacy: .public)'")
        return nil
    }

    /// Applies diacritics-insensitive folding, lowercasing, and whitespace trimming.
    /// `internal` so it is accessible from the test target via `@testable import`.
    nonisolated static func normalizeArtistName(_ name: String) -> String {
        LibraryIndexText.normalized(name)
    }

    private func offlineSmartShuffle(targetSize: Int) async -> [DisplayableSong] {
        guard let activeServerId = await MainActor.run(body: { serverService.state.activeServer?.id }) else {
            Logger.library.debug("Smart shuffle offline: no active server, returning empty")
            return []
        }

        let songs: [DisplayableSong] = await MainActor.run {
            let context = ModelContext(modelContainer)
            let descriptor = FetchDescriptor<DownloadedTrack>(
                predicate: #Predicate<DownloadedTrack> { $0.serverId == activeServerId }
            )
            let downloads = (try? context.fetch(descriptor)) ?? []
            guard !downloads.isEmpty else {
                Logger.library.debug("Smart shuffle offline: no downloads available")
                return []
            }
            let selected = Array(downloads.shuffled().prefix(targetSize))
            Logger.library.debug("Smart shuffle offline: \(selected.count) tracks from \(downloads.count) downloads")
            return selected.map { DisplayableSong(from: $0) }
        }

        return songs
    }
}
