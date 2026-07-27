import Foundation

struct AlbumRecommendation: Sendable, Equatable, Hashable {
    let id: String?
    let title: String
    let artistName: String
    let releaseDate: Date?
    let coverArtURL: URL?
    let inLibrary: Bool
}
