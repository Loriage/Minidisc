// Minidisc — Music client for Subsonic/OpenSubsonic servers
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

protocol AudioStreamCacheProtocol: AnyObject, Sendable {
    var usedBytes: Int64 { get async }
    var trackCount: Int { get async }

    func cachedURL(forSongId songId: String, serverId: UUID) async -> URL?

    /// Moves a completed download into the cache without materialising the whole track in RAM.
    func store(fileAt sourceURL: URL, forSongId songId: String, serverId: UUID, mimeType: String) async throws -> URL

    /// Updates the maximum number of cached tracks. Triggers FIFO eviction if current count exceeds the new limit.
    func setMaxTracks(_ value: Int) async

    /// Removes a single record and its file immediately (e.g. on stale-file detection).
    func invalidate(songId: String, serverId: UUID) async

    /// Deletes every cached track and file — called by "Clear cache now".
    func clearAll() async

    /// Deletes all cached tracks for a specific server.
    func clearAllForServer(_ serverId: UUID) async
}
