import Foundation

/// Persisted failed scrobble. nonisolated keeps Codable usable across actor boundaries.
nonisolated struct PendingListen: Codable, Sendable, Equatable {
    let listenedAt: Int
    let trackName: String
    let artistName: String
    let releaseName: String?
    /// Duration in milliseconds; included in the import payload for parity with live submits.
    /// Optional to handle legacy queue files written before this field was added.
    let durationMs: Int?
}
