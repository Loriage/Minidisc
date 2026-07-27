import Foundation

nonisolated struct SimilarArtistRecommendation: Sendable, Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let coverArt: String?
    let inLibrary: Bool
    /// MusicBrainz ID, present for LB-sourced results. nil for Subsonic-only results.
    let mbid: String?
}
