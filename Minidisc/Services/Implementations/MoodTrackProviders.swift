import Foundation
import SwiftSonic
import OSLog

nonisolated protocol MoodTrackProvider: Sendable {
    var kind: MoodSourceKind { get }
    func prepare() async
    /// Track ids for a mood, best match first. Empty means "no confident answer" — never a reason
    /// to overwrite an existing playlist.
    func trackIds(for mood: Mood, limit: Int) async throws -> [String]
}

nonisolated enum MoodSourceKind: String, Sendable, Equatable {
    case sonic
    case tags
}

/// Resolves internal AudioMuse IDs through track metadata while preserving similarity order.
nonisolated struct AudioMuseTrackProvider: MoodTrackProvider {
    let client: AudioMuseClient
    let resolver: SubsonicTrackResolver?

    init(client: AudioMuseClient, resolver: SubsonicTrackResolver? = nil) {
        self.client = client
        self.resolver = resolver
    }

    var kind: MoodSourceKind { .sonic }

    func prepare() async { await client.warmup() }

    func trackIds(for mood: Mood, limit: Int) async throws -> [String] {
        let results = try await client.search(query: mood.query, limit: limit)
        guard !results.isEmpty else { return [] }

        // Usable ids keep their position; the rest are looked up by name. Order is preserved
        // because it is AudioMuse's similarity ranking — the best matches come first.
        var ids: [String] = []
        var unresolvable = 0
        var recovered = 0
        for track in results {
            if !track.hasInternalId {
                ids.append(track.itemId)
            } else if let resolver, let descriptor = track.descriptor, let id = await resolver.resolve(descriptor) {
                ids.append(id)
                recovered += 1
            } else {
                unresolvable += 1
            }
        }

        Logger.moodPlaylists.info("[MOOD-SONIC] \(mood.rawValue, privacy: .public): \(results.count, privacy: .public) results → \(ids.count, privacy: .public) usable (\(recovered, privacy: .public) recovered by name, \(unresolvable, privacy: .public) lost)")

        // Everything came back with an unusable id and nothing could be found in the library: the
        // caller must not treat that as a successful, empty playlist.
        if ids.isEmpty && !results.isEmpty { throw AudioMuseError.internalIdsOnly }
        return ids
    }
}

/// Ranks genre-query candidates by local tags when AudioMuse is unavailable.
nonisolated struct LibraryTagTrackProvider: MoodTrackProvider {
    let libraryService: any MoodTrackSourcing

    static let perGenreFetch = 200

    var kind: MoodSourceKind { .tags }

    func prepare() async {}

    static let fallbackPoolSize = 500

    func trackIds(for mood: Mood, limit: Int) async throws -> [String] {
        try Task.checkCancellation()
        var candidates = try await genreCandidates(for: mood)
        var source = "genres"

        if candidates.isEmpty {
            candidates = try await randomCandidates()
            source = "random pool"
        }
        try Task.checkCancellation()

        let ranked = MoodTagMatcher.rank(candidates, for: mood, limit: limit)
        let withMoodTag = candidates.count { !$0.features.moods.isEmpty }
        let withBpm = candidates.count { ($0.features.bpm ?? 0) > 0 }
        Logger.moodPlaylists.info("[MOOD-TAGS] \(mood.rawValue, privacy: .public): \(candidates.count, privacy: .public) candidates via \(source, privacy: .public) (\(withMoodTag, privacy: .public) tagged, \(withBpm, privacy: .public) with BPM) → \(ranked.count, privacy: .public) ranked")
        return ranked
    }

    private func genreCandidates(
        for mood: Mood
    ) async throws -> [(id: String, features: SongTagFeatures)] {
        var seen = Set<String>()
        var candidates: [(id: String, features: SongTagFeatures)] = []
        for genre in MoodTagMatcher.genres(mood) {
            try Task.checkCancellation()
            // A genre the library simply does not have is normal, not an error — skip and continue,
            // otherwise one absent genre would sink the whole mood.
            let songs: [Song]
            do {
                songs = try await libraryService.songsByGenre(
                    genre,
                    count: Self.perGenreFetch
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                continue
            }
            try Task.checkCancellation()
            for song in songs where seen.insert(song.id).inserted {
                candidates.append((song.id, Self.features(of: song)))
            }
        }
        return candidates
    }

    private func randomCandidates() async throws -> [(id: String, features: SongTagFeatures)] {
        do {
            let songs = try await libraryService.randomSongs(size: Self.fallbackPoolSize)
            try Task.checkCancellation()
            return songs.map { ($0.id, Self.features(of: $0)) }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return []
        }
    }

    /// Reads both genre spellings: OpenSubsonic's `genres` array and the older single `genre`
    /// string, since servers populate one, the other, or both.
    static func features(of song: Song) -> SongTagFeatures {
        var genres = song.genres?.map(\.name) ?? []
        if let legacy = song.genre, !genres.contains(legacy) { genres.append(legacy) }
        return SongTagFeatures(moods: song.moods ?? [], genres: genres, bpm: song.bpm)
    }
}
