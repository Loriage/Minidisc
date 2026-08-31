import Foundation
import SwiftSonic

/// A seed for an AudioMuse-AI Instant Mix. The case decides which Subsonic similarity endpoint is used:
/// song/album seeds go through the folder-based `getSimilarSongs`, an artist seed through the ID3-based
/// `getSimilarSongs2`. ("Radio" is deliberately avoided — it means Internet radio stations elsewhere.)
nonisolated enum InstantMixSeed: Sendable, Hashable {
    case song(id: String)
    case album(id: String)
    case artist(id: String)
}

/// Focused seams for callers that consume only one catalogue capability. They keep
/// view-model fakes small without splitting the concrete library implementation.
nonisolated protocol LibrarySearching: AnyObject, Sendable {
    func search(_ query: String) async throws -> SearchResult3
}

nonisolated protocol AlbumBrowsing: AnyObject, Sendable {
    func album(id: String) async throws -> AlbumID3
    func allAlbums() async throws -> [AlbumID3]
}

nonisolated protocol ArtistBrowsing: AnyObject, Sendable {
    func artists() async throws -> [ArtistIndex]
    func artist(id: String) async throws -> ArtistID3

    /// Fetches every track from every album of the given artist.
    /// Albums are ordered most-recent first (by year); albums without a year come last (alphabetical).
    /// Uses a TaskGroup bounded to 5 concurrent album fetches — safe for home-server instances.
    /// Individual album failures are logged and skipped (best-effort). Throws `MinidiscError.artistTracksUnavailable`
    /// only when every album fetch fails.
    func fetchAllTracks(forArtistID artistID: String) async throws -> [DisplayableSong]
}

nonisolated protocol SongBrowsing: AnyObject, Sendable {
    func allSongs(offset: Int, count: Int) async throws -> [Song]
}

nonisolated protocol PlaylistBrowsing: AnyObject, Sendable {
    func playlists() async throws -> [Playlist]
    func playlist(id: String) async throws -> PlaylistWithSongs
}

nonisolated protocol StarredBrowsing: AnyObject, Sendable {
    func getStarred2() async throws -> Starred2
}

nonisolated protocol FavoriteEditing: StarredBrowsing {
    func star(songIds: [String], albumIds: [String], artistIds: [String]) async throws
    func unstar(songIds: [String], albumIds: [String], artistIds: [String]) async throws
}

nonisolated protocol RecentlyAddedAlbumBrowsing: AnyObject, Sendable {
    func recentlyAddedAlbums(size: Int) async throws -> [AlbumID3]
}

nonisolated protocol ListeningHistoryBrowsing: AnyObject, Sendable {
    func recentlyPlayedAlbums(size: Int) async throws -> [AlbumID3]
    func mostPlayedAlbums(size: Int) async throws -> [AlbumID3]
}

nonisolated protocol RecentlyAddedTrackBrowsing: AnyObject, Sendable {
    /// Builds the virtual "Recently Added" playlist from the newest albums because
    /// plain Subsonic has no track-level recency endpoint.
    func recentlyAddedTracks(albumLimit: Int, trackLimit: Int) async throws -> [Song]
}

nonisolated protocol GenreBrowsing: AnyObject, Sendable {
    func genres() async throws -> [Genre]
    func albumsByGenre(_ genre: String, size: Int) async throws -> [AlbumID3]
}

nonisolated protocol MoodTrackSourcing: AnyObject, Sendable {
    /// Keeps the raw OpenSubsonic mood and BPM tags used by the local mood matcher.
    func songsByGenre(_ genre: String, count: Int) async throws -> [Song]
    func randomSongs(size: Int) async throws -> [Song]
}

nonisolated protocol ArtistRecommendationBrowsing: AnyObject, Sendable {
    /// May trigger external Last.fm/MusicBrainz work on some servers; the concrete service
    /// applies a bounded timeout and caches results per active connection.
    func getArtistInfo(forArtistID artistID: String, count: Int) async throws -> ArtistInfo
    func getArtistMBID(forArtistID artistID: String) async throws -> String?
    func findArtist(byName name: String) async -> ArtistID3?
    func topSongs(artist: String, count: Int) async throws -> [DisplayableSong]
}

nonisolated protocol AlbumRecommendationBrowsing: AnyObject, Sendable {
    /// Derives album recommendations from the server's similar-song graph.
    /// Albums by the current artist are excluded because the album screen already presents them in “More by”.
    func similarAlbums(
        to albumID: String,
        excludingArtistID artistID: String?,
        excludingArtistName artistName: String?,
        limit: Int
    ) async throws -> [AlbumID3]
}

nonisolated protocol PlaybackQueueBuilding: AnyObject, Sendable {
    /// Smart Shuffle is truly random online and limited to downloaded tracks offline.
    func smartShuffleQueue(targetSize: Int) async throws -> [DisplayableSong]
    /// Builds a best-effort similarity queue while excluding the current queue and recent listens.
    func similarBackfillQueue(targetSize: Int, excludedIds: Set<String>) async throws -> [DisplayableSong]
    func instantMix(from seed: InstantMixSeed, count: Int) async throws -> [DisplayableSong]
    func endlessExtension(seedTrackId: String?, targetSize: Int, excludedIds: Set<String>) async throws -> [DisplayableSong]
}

nonisolated protocol PlaybackReporting: AnyObject, Sendable {
    /// `submission: false` reports now-playing; `true` submits a completed listen.
    /// Reporting failures never interrupt playback.
    func scrobble(songId: String, submission: Bool) async
}

nonisolated protocol ArtworkURLResolving: AnyObject, Sendable {
    func coverArtURL(id: String, size: Int?) async -> URL?
}

nonisolated protocol LibraryServiceProtocol:
    LibrarySearching,
    AlbumBrowsing,
    ArtistBrowsing,
    SongBrowsing,
    PlaylistBrowsing,
    FavoriteEditing,
    RecentlyAddedAlbumBrowsing,
    ListeningHistoryBrowsing,
    RecentlyAddedTrackBrowsing,
    GenreBrowsing,
    MoodTrackSourcing,
    ArtistRecommendationBrowsing,
    AlbumRecommendationBrowsing,
    PlaybackQueueBuilding,
    PlaybackReporting,
    ArtworkURLResolving
{
    func streamURL(songId: String) async -> URL?
}

extension RecentlyAddedTrackBrowsing where Self: RecentlyAddedAlbumBrowsing, Self: AlbumBrowsing {
    /// Composition of `recentlyAddedAlbums` + `album(id:)` — the only way to reach tracks on a plain Subsonic
    /// server. Lives here rather than in `LibraryService` because there is nothing server-specific to
    /// customise: any conformer that can list its newest albums and open one gets the playlist for free.
    func recentlyAddedTracks(albumLimit: Int, trackLimit: Int) async throws -> [Song] {
        let albums = try await recentlyAddedAlbums(size: albumLimit)
        guard !albums.isEmpty else { return [] }
        try Task.checkCancellation()

        // Bounded to 5 concurrent album fetches — the same ceiling `fetchAllTracks` holds home servers to.
        let maxInFlight = 5
        var collected: [(index: Int, songs: [Song])] = []
        var submitted = 0

        await withTaskGroup(of: (Int, [Song]).self) { group in
            while submitted < min(maxInFlight, albums.count) {
                let index = submitted
                let albumId = albums[index].id
                group.addTask { (index, await self.tracks(ofAlbum: albumId)) }
                submitted += 1
            }
            while let entry = await group.next() {
                collected.append(entry)
                // Stop feeding the group once cancelled, but keep draining it so the group exits cleanly.
                guard !Task.isCancelled, submitted < albums.count else { continue }
                let index = submitted
                let albumId = albums[index].id
                group.addTask { (index, await self.tracks(ofAlbum: albumId)) }
                submitted += 1
            }
        }
        try Task.checkCancellation()

        return RecentlyAdded.tracks(from: collected, limit: trackLimit)
    }

    /// One album's tracks, best-effort: an album the server can't serve contributes nothing instead of
    /// failing the whole list.
    private func tracks(ofAlbum albumId: String) async -> [Song] {
        guard let detail = try? await album(id: albumId) else { return [] }
        return detail.song ?? []
    }
}

extension PlaybackQueueBuilding {
    /// Default composition of `instantMix` + `similarBackfillQueue` — conformers get the endless
    /// behaviour without changes, mirroring how Instant Mix itself degrades without a similarity
    /// service.
    func endlessExtension(seedTrackId: String?, targetSize: Int, excludedIds: Set<String>) async throws -> [DisplayableSong] {
        guard let seedTrackId else {
            return try await similarBackfillQueue(targetSize: targetSize, excludedIds: excludedIds)
        }
        var picked: [DisplayableSong] = []
        var seen = excludedIds
        let mix: [DisplayableSong]
        do {
            mix = try await instantMix(from: .song(id: seedTrackId), count: targetSize)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            mix = []
        }
        try Task.checkCancellation()
        for song in mix where !seen.contains(song.id) {
            picked.append(song)
            seen.insert(song.id)
        }
        // A short (or empty) similar set is topped up from the library heuristic.
        if picked.count < targetSize {
            let backfill: [DisplayableSong]
            do {
                backfill = try await similarBackfillQueue(
                    targetSize: targetSize - picked.count,
                    excludedIds: seen
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                backfill = []
            }
            try Task.checkCancellation()
            picked.append(contentsOf: backfill.filter { !seen.contains($0.id) })
        }
        return picked
    }
}
