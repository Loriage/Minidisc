import Foundation
import OSLog

// MARK: - HTTP client protocol (testable)

nonisolated protocol ArtistImageHTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: ArtistImageHTTPClient {}

// MARK: - MusicBrainz rate limiter

/// Grants one MusicBrainz request at a time, separated by `minimumInterval`.
///
/// Waiters are queued rather than assigned future timestamps. Removing a cancelled waiter therefore
/// does not leave an unused reservation (and an unnecessary extra delay) in the schedule.
actor MusicBrainzRateLimiter {
    typealias Sleeper = @Sendable (Duration) async throws -> Void

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let minimumInterval: Duration
    private let sleeper: Sleeper
    private var permitAvailable = true
    private var waiters: [Waiter] = []
    private var cooldownTask: Task<Void, Never>?

    init(
        minimumInterval: Duration = .seconds(1),
        sleeper: Sleeper? = nil
    ) {
        self.minimumInterval = minimumInterval
        self.sleeper = sleeper ?? { duration in
            try await Task.sleep(for: duration)
        }
    }

    func waitForPermit() async throws {
        try Task.checkCancellation()

        if permitAvailable {
            permitAvailable = false
            startCooldown()
            guard !Task.isCancelled else {
                recoverGrantedPermit()
                throw CancellationError()
            }
            return
        }

        let waiterID = UUID()
        let granted = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters.append(Waiter(id: waiterID, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID) }
        }
        guard granted else { throw CancellationError() }
        guard !Task.isCancelled else {
            recoverGrantedPermit()
            throw CancellationError()
        }
    }

    private func startCooldown() {
        let minimumInterval = self.minimumInterval
        let sleeper = self.sleeper
        cooldownTask = Task { [weak self] in
            do {
                try await sleeper(minimumInterval)
            } catch {
                // A cancelled cooldown was deliberately replaced by recoverGrantedPermit(). Any
                // other sleeper failure must still hand the permit on; otherwise one injected clock
                // error wedges every future MusicBrainz request for the lifetime of the actor.
                guard !Task.isCancelled else { return }
                await self?.cooldownFinished()
                return
            }
            guard !Task.isCancelled else { return }
            await self?.cooldownFinished()
        }
    }

    private func cooldownFinished() {
        cooldownTask = nil
        guard !waiters.isEmpty else {
            permitAvailable = true
            return
        }
        let waiter = waiters.removeFirst()
        waiter.continuation.resume(returning: true)
        startCooldown()
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }

    private func recoverGrantedPermit() {
        cooldownTask?.cancel()
        cooldownTask = nil
        guard !waiters.isEmpty else {
            permitAvailable = true
            return
        }
        let waiter = waiters.removeFirst()
        waiter.continuation.resume(returning: true)
        startCooldown()
    }

    /// Deterministic test seam.
    func waitingCount() -> Int {
        waiters.count
    }
}

// MARK: - Actor

/// Resolves out-of-library artist photos via MusicBrainz → Wikidata → Wikimedia Commons.
/// Supports both MBID-based lookup (LB-sourced recommendations) and name-based search
/// (Subsonic provider, which does not supply MBIDs).
/// Results are cached in-memory; concurrent requests for the same artist share a single Task.
actor ExternalArtistImageResolver {
    private enum CachedResolution {
        case hit(URL)
        case miss

        var url: URL? {
            switch self {
            case .hit(let url): url
            case .miss: nil
            }
        }
    }

    private struct InFlightEntry {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<URL?, Never>]
    }

    private let httpClient: any ArtistImageHTTPClient
    /// Keys: "mbid:<mbid>" or "name:<normalized-name>"
    private var cache: [String: CachedResolution] = [:]
    private var inflight: [String: InFlightEntry] = [:]
    private let musicBrainzRateLimiter: MusicBrainzRateLimiter

    init(
        httpClient: any ArtistImageHTTPClient = URLSession.shared,
        minimumMBRequestInterval: Duration = .seconds(1)
    ) {
        self.httpClient = httpClient
        musicBrainzRateLimiter = MusicBrainzRateLimiter(minimumInterval: minimumMBRequestInterval)
    }

    // MARK: - Public API

    /// Unified entry point: uses the MBID when available, otherwise searches MB by name.
    func resolveImageURL(for recommendation: SimilarArtistRecommendation) async -> URL? {
        if let mbid = recommendation.mbid?.trimmingCharacters(in: .whitespacesAndNewlines),
           !mbid.isEmpty {
            return await resolveImageURL(forArtistMBID: mbid)
        }
        return await resolveImageURL(forArtistName: recommendation.name)
    }

    /// Resolves via a known MusicBrainz ID → Wikidata → Wikimedia Commons.
    func resolveImageURL(forArtistMBID mbid: String) async -> URL? {
        let trimmed = mbid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            Logger.artistArtwork.debug("Skipped resolution: empty MBID")
            return nil
        }
        return await resolve(key: "mbid:\(trimmed)") { await self.pipeline(mbid: trimmed) }
    }

    /// Searches MusicBrainz for the artist by name, then runs the MB→Wikidata→Commons pipeline.
    func resolveImageURL(forArtistName name: String) async -> URL? {
        let normalized = name.lowercased().trimmingCharacters(in: .whitespaces)
        return await resolve(key: "name:\(normalized)") {
            guard let mbid = await self.searchMBID(forName: name) else { return nil }
            return await self.pipeline(mbid: mbid)
        }
    }

    /// Deterministic concurrency-test seam.
    func inFlightWaiterCount(forArtistMBID mbid: String) -> Int {
        inflight["mbid:\(mbid.trimmingCharacters(in: .whitespacesAndNewlines))"]?
            .waiters.count ?? 0
    }

    // MARK: - Cache / dedup helper

    private func resolve(key: String, work: @escaping @Sendable () async -> URL?) async -> URL? {
        guard !Task.isCancelled else { return nil }
        if let cached = cache[key] { return cached.url }
        let waiterID = UUID()
        if let existing = inflight[key] {
            return await waitForResolution(
                key: key,
                requestID: existing.id,
                waiterID: waiterID
            )
        }

        let requestID = UUID()
        let task = Task<Void, Never> { [weak self] in
            let result = await work()
            let wasCancelled = Task.isCancelled
            await self?.completeResolution(
                key: key,
                requestID: requestID,
                result: result,
                wasCancelled: wasCancelled
            )
        }
        inflight[key] = InFlightEntry(id: requestID, task: task, waiters: [:])
        return await waitForResolution(
            key: key,
            requestID: requestID,
            waiterID: waiterID
        )
    }

    private func waitForResolution(
        key: String,
        requestID: UUID,
        waiterID: UUID
    ) async -> URL? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard var entry = inflight[key], entry.id == requestID else {
                    continuation.resume(returning: Task.isCancelled ? nil : cache[key]?.url)
                    return
                }
                entry.waiters[waiterID] = continuation
                inflight[key] = entry
                if Task.isCancelled {
                    cancelResolutionWaiter(
                        key: key,
                        requestID: requestID,
                        waiterID: waiterID
                    )
                }
            }
        } onCancel: {
            Task {
                await self.cancelResolutionWaiter(
                    key: key,
                    requestID: requestID,
                    waiterID: waiterID
                )
            }
        }
    }

    private func cancelResolutionWaiter(
        key: String,
        requestID: UUID,
        waiterID: UUID
    ) {
        guard var entry = inflight[key],
              entry.id == requestID,
              let continuation = entry.waiters.removeValue(forKey: waiterID) else { return }
        continuation.resume(returning: nil)
        guard entry.waiters.isEmpty else {
            inflight[key] = entry
            return
        }
        inflight.removeValue(forKey: key)
        entry.task.cancel()
    }

    private func completeResolution(
        key: String,
        requestID: UUID,
        result: URL?,
        wasCancelled: Bool
    ) {
        guard let entry = inflight[key], entry.id == requestID else { return }
        inflight.removeValue(forKey: key)
        if !wasCancelled {
            cache[key] = result.map(CachedResolution.hit) ?? .miss
        }
        let resolvedResult = wasCancelled ? nil : result
        entry.waiters.values.forEach { $0.resume(returning: resolvedResult) }
    }

    // MARK: - Pipeline stages

    private func pipeline(mbid: String) async -> URL? {
        guard let wikidataID = await fetchWikidataID(mbid: mbid) else { return nil }
        guard let filename = await fetchCommonsFilename(wikidataID: wikidataID) else { return nil }
        guard let encoded = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "https://commons.wikimedia.org/wiki/Special:FilePath/\(encoded)?width=500")
    }

    private func searchMBID(forName name: String) async -> String? {
        let normalized = name.lowercased().trimmingCharacters(in: .whitespaces)
            .folding(options: .diacriticInsensitive, locale: .current)

        var components = URLComponents(string: "https://musicbrainz.org/ws/2/artist")!
        components.queryItems = [
            URLQueryItem(name: "query", value: "artist:\"\(name)\""),
            URLQueryItem(name: "limit", value: "3"),
            URLQueryItem(name: "fmt", value: "json"),
        ]
        guard let url = components.url else { return nil }

        var req = URLRequest(url: url)
        req.setValue("Minidisc/1.0 (https://github.com/Loriage/Minidisc)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10

        do {
            try await musicBrainzRateLimiter.waitForPermit()
            let (data, _) = try await httpClient.data(for: req)
            let decoded = try JSONDecoder().decode(MBsearchResponse.self, from: data)
            let artists = decoded.artists ?? []

            let match = artists.first { candidate in
                let score = candidate.score ?? 0
                if score >= 90 { return true }
                if score >= 80 {
                    let candidateNorm = candidate.name.lowercased().trimmingCharacters(in: .whitespaces)
                        .folding(options: .diacriticInsensitive, locale: .current)
                    return candidateNorm == normalized
                }
                return false
            }

            if let match {
                Logger.artistArtwork.debug("MB search resolved '\(name, privacy: .public)' → MBID=\(match.id, privacy: .public) score=\(match.score ?? 0, privacy: .public)")
                return match.id
            }
            Logger.artistArtwork.debug("MB search no match for '\(name, privacy: .public)' (best score=\(artists.first?.score ?? 0, privacy: .public))")
            return nil
        } catch is CancellationError {
            return nil
        } catch {
            guard !Task.isCancelled else { return nil }
            Logger.artistArtwork.warning("MB search failed for '\(name, privacy: .public)': \(error, privacy: .public)")
            return nil
        }
    }

    private func fetchWikidataID(mbid: String) async -> String? {
        guard let reqURL = URL(string: "https://musicbrainz.org/ws/2/artist/\(mbid)?inc=url-rels&fmt=json") else {
            Logger.artistArtwork.warning("fetchWikidataID: could not build URL for MBID=\(mbid, privacy: .public)")
            return nil
        }
        var req = URLRequest(url: reqURL)
        req.setValue("Minidisc/1.0 (https://github.com/Loriage/Minidisc)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10

        do {
            try await musicBrainzRateLimiter.waitForPermit()
            let (data, _) = try await httpClient.data(for: req)
            let decoded = try JSONDecoder().decode(MBartistResponse.self, from: data)
            let wikidataRel = decoded.relations?.first {
                $0.type == "wikidata" && $0.url?.resource.contains("wikidata.org/wiki/Q") == true
            }
            guard let resource = wikidataRel?.url?.resource,
                  let qid = resource.components(separatedBy: "/").last,
                  qid.hasPrefix("Q") else {
                Logger.artistArtwork.debug("No Wikidata relation for MBID=\(mbid, privacy: .public)")
                return nil
            }
            Logger.artistArtwork.debug("MBID=\(mbid, privacy: .public) → Wikidata=\(qid, privacy: .public)")
            return qid
        } catch is CancellationError {
            return nil
        } catch {
            guard !Task.isCancelled else { return nil }
            Logger.artistArtwork.warning("MB fetch failed for MBID=\(mbid, privacy: .public): \(error, privacy: .public)")
            return nil
        }
    }

    private func fetchCommonsFilename(wikidataID: String) async -> String? {
        let urlString = "https://www.wikidata.org/w/api.php?action=wbgetentities&ids=\(wikidataID)&props=claims&format=json"
        guard let reqURL = URL(string: urlString) else {
            Logger.artistArtwork.warning("fetchCommonsFilename: could not build URL for Wikidata=\(wikidataID, privacy: .public)")
            return nil
        }
        let req = URLRequest(url: reqURL, timeoutInterval: 10)

        do {
            let (data, _) = try await httpClient.data(for: req)
            let decoded = try JSONDecoder().decode(WDentitiesResponse.self, from: data)
            guard let claims = decoded.entities[wikidataID]?.claims,
                  let p18 = claims["P18"]?.first?.mainsnak.datavalue?.value else {
                Logger.artistArtwork.debug("No P18 for Wikidata=\(wikidataID, privacy: .public)")
                return nil
            }
            Logger.artistArtwork.debug("Wikidata=\(wikidataID, privacy: .public) P18=\(p18, privacy: .public)")
            return p18
        } catch is CancellationError {
            return nil
        } catch {
            guard !Task.isCancelled else { return nil }
            Logger.artistArtwork.warning("Wikidata fetch failed for \(wikidataID, privacy: .public): \(error, privacy: .public)")
            return nil
        }
    }
}

// MARK: - MusicBrainz response models

nonisolated private struct MBsearchResponse: Decodable {
    let artists: [MBartistCandidate]?
}

nonisolated private struct MBartistCandidate: Decodable {
    let id: String
    let name: String
    let score: Int?
}

nonisolated private struct MBartistResponse: Decodable {
    let relations: [MBrelation]?
}

nonisolated private struct MBrelation: Decodable {
    let type: String
    let url: MBurl?
}

nonisolated private struct MBurl: Decodable {
    let resource: String
}

// MARK: - Wikidata response models

nonisolated private struct WDentitiesResponse: Decodable {
    let entities: [String: WDentity]
}

nonisolated private struct WDentity: Decodable {
    let claims: [String: [WDclaim]]?
}

nonisolated private struct WDclaim: Decodable {
    let mainsnak: WDmainsnak
}

nonisolated private struct WDmainsnak: Decodable {
    let datavalue: WDdatavalue?
}

nonisolated private struct WDdatavalue: Decodable {
    /// P18 values are plain strings (Commons filenames). Other property types use nested
    /// objects — we decode only the string case and return nil for everything else.
    let value: String?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = try? container.decode(String.self, forKey: .value)
    }

    private enum CodingKeys: String, CodingKey { case value }
}
