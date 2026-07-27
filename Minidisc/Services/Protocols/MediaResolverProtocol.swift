import Foundation
import SwiftSonic

/// Single entry point for obtaining a playable URL for a given song.
/// Resolution order: downloaded → cached → stream.
/// PlayerService always calls this — never SwiftSonic directly.
protocol MediaResolverProtocol: AnyObject, Sendable {
    func resolve(songId: String, serverId: UUID) async throws -> MediaSource
    func resolveRadio(_ station: InternetRadioStation) async throws -> MediaSource
}
