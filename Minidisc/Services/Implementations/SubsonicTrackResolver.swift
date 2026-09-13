import Foundation
import SwiftSonic
import OSLog

/// Resolves AudioMuse metadata to library IDs. Caches both matches and misses across moods.
actor SubsonicTrackResolver {
    private let libraryService: any LibrarySearching
    private var resolved: [String: String] = [:]
    private var missed: Set<String> = []

    init(libraryService: any LibrarySearching) {
        self.libraryService = libraryService
    }

    func resolve(_ descriptor: TrackDescriptor) async -> String? {
        let key = descriptor.cacheKey
        if let hit = resolved[key] { return hit }
        if missed.contains(key) { return nil }

        // Title and artist together, because a bare title returns the whole library's worth of
        // "Intro" and the server ranks better with both.
        let query = [descriptor.title, descriptor.artist].compactMap { $0 }.joined(separator: " ")
        guard let result = try? await libraryService.search(query) else {
            // A transient failure is not a miss — leaving it uncached lets the next run retry.
            return nil
        }

        let candidates = (result.song ?? []).map {
            TrackDescriptor.Candidate(id: $0.id, title: $0.title, artist: $0.artist)
        }
        guard let match = TrackMatcher.bestMatch(for: descriptor, among: candidates) else {
            missed.insert(key)
            return nil
        }
        resolved[key] = match
        return match
    }

    /// Resolves sequentially to limit server load, preserving input order and dropping misses.
    func resolveAll(_ descriptors: [TrackDescriptor]) async -> [String] {
        var ids: [String] = []
        for descriptor in descriptors {
            if let id = await resolve(descriptor) { ids.append(id) }
        }
        return ids
    }
}
