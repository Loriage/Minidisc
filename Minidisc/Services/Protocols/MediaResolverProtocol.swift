import Foundation
import SwiftSonic

nonisolated enum MediaAvailability: String, Sendable, Equatable {
    case available
    case missing
    /// Connectivity, authentication, or an unsupported endpoint cannot prove a deletion.
    case unknown
}

/// Single entry point for obtaining a playable URL for a given song.
/// Resolution order: downloaded → cached → stream.
/// PlayerService always calls this — never SwiftSonic directly.
nonisolated protocol MediaResolverProtocol: AnyObject, Sendable {
    func resolve(songId: String, serverId: UUID) async throws -> MediaSource
    func resolveRadio(_ station: InternetRadioStation) async throws -> MediaSource
    /// Checks the authoritative server only after playback fails; local audio remains playable.
    func availability(songId: String, serverId: UUID) async -> MediaAvailability
}
