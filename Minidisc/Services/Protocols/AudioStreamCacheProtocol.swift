import Foundation

protocol AudioStreamCacheProtocol: AnyObject, Sendable {
    var usedBytes: Int64 { get async }
    var trackCount: Int { get async }

    func cachedURL(forSongId songId: String, serverId: UUID) async -> URL?

    /// Moves a completed download into the cache without materialising the whole track in RAM.
    func store(fileAt sourceURL: URL, forSongId songId: String, serverId: UUID, mimeType: String) async throws -> URL

    /// Updates the cache byte capacity and evicts least-recently-used entries as needed.
    func setMaxBytes(_ value: Int64) async

    /// Removes a single record and its file immediately (e.g. on stale-file detection).
    func invalidate(songId: String, serverId: UUID) async

    /// Deletes every cached track and file — called by "Clear cache now".
    func clearAll() async

    /// Deletes all cached tracks for a specific server.
    func clearAllForServer(_ serverId: UUID) async
}
