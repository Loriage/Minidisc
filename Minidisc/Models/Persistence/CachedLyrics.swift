import Foundation
import SwiftData

@Model
final class CachedLyrics {
    @Attribute(.unique) var compositeKey: String
    var songId: String
    var serverId: UUID
    var jsonPayload: Data  // serialized LyricsList — see LyricsEncoding.swift for Encodable conformance
    var fetchedAt: Date

    init(
        songId: String,
        serverId: UUID,
        jsonPayload: Data,
        provider: LyricsProvider = .navidrome
    ) {
        self.compositeKey = Self.key(songId: songId, serverId: serverId, provider: provider)
        self.songId = songId
        self.serverId = serverId
        self.jsonPayload = jsonPayload
        self.fetchedAt = Date()
    }

    static func key(songId: String, serverId: UUID, provider: LyricsProvider) -> String {
        "\(serverId.uuidString):\(provider.rawValue):\(songId)"
    }
}
