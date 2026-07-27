import Foundation

protocol RecommendationProvider: Sendable {
    func similarArtists(toArtistID: String, limit: Int) async throws -> [SimilarArtistRecommendation]
    func freshReleases(limit: Int, daysWindow: Int) async throws -> [AlbumRecommendation]
}

extension RecommendationProvider {
    func similarArtists(toArtistID: String, limit: Int) async throws -> [SimilarArtistRecommendation] { [] }
    func freshReleases(limit: Int, daysWindow: Int) async throws -> [AlbumRecommendation] { [] }
}
