import Foundation
import SwiftSonic

nonisolated enum MediaAvailability: String, Sendable, Equatable {
    case available
    case missing
    /// Connectivity, authentication, or an unsupported endpoint cannot prove a deletion.
    case unknown
}

/// Resolves playable media in order: permanent download, cache, remote stream.
nonisolated protocol MediaResolverProtocol: AnyObject, Sendable {
    /// Looks for completed local audio without contacting the server, even while offline.
    func localSource(songId: String, serverId: UUID) async -> MediaSource?
    func resolve(songId: String, serverId: UUID) async throws -> MediaSource
    func resolveRadio(_ station: InternetRadioStation) async throws -> MediaSource
    /// Checks the authoritative server only after playback fails; local audio remains playable.
    func availability(songId: String, serverId: UUID) async -> MediaAvailability
}
