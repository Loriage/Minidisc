import Foundation

nonisolated protocol LidarrArtistResolving: Sendable {
    func searchArtists(term: String) async throws -> [LidarrArtistLookup]
    func artist(id: Int) async throws -> LidarrArtist
}

extension LidarrClient: LidarrArtistResolving {}

nonisolated enum LidarrArtistResolution: Sendable {
    case add(LidarrArtistLookup)
    case existing(LidarrArtist)
    case search
    case notFound
}

nonisolated enum LidarrArtistResolver {
    static func resolve(mbid: String?, using client: any LidarrArtistResolving) async throws -> LidarrArtistResolution {
        try Task.checkCancellation()
        guard let mbid, let identifier = UUID(uuidString: mbid.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return .search
        }
        let results = try await client.searchArtists(term: "lidarr:\(identifier.uuidString.lowercased())")
        try Task.checkCancellation()
        let matches = results.filter { UUID(uuidString: $0.foreignArtistId) == identifier }
        guard matches.count == 1, let match = matches.first else { return .notFound }
        guard let existingID = match.existingId, existingID > 0 else { return .add(match) }
        let artist = try await client.artist(id: existingID)
        try Task.checkCancellation()
        guard artist.id == existingID, artist.foreignArtistId.flatMap(UUID.init(uuidString:)) == identifier else {
            return .notFound
        }
        return .existing(artist)
    }
}
