import Foundation

protocol AudioStreamCacheProtocol: AnyObject, Sendable {
    var usedBytes: Int64 { get async }
    var trackCount: Int { get async }

    func cachedURL(forSongId songId: String, serverId: UUID) async -> URL?

    /// Moves a completed download into the cache without materialising the whole track in RAM.
    func store(fileAt sourceURL: URL, forSongId songId: String, serverId: UUID, mimeType: String) async throws -> URL

    func setMaxBytes(_ value: Int64) async

    func invalidate(songId: String, serverId: UUID) async

    func clearAll() async

    func clearAllForServer(_ serverId: UUID) async
}
