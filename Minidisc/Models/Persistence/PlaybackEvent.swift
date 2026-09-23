import Foundation
import SwiftData

@Model
final class PlaybackEvent {
    #Index<PlaybackEvent>([\.timestamp], [\.serverId])

    var timestamp: Date
    var serverId: String

    var id: UUID
    var trackId: String
    var trackTitle: String
    var albumId: String?
    var albumTitle: String?
    var artistId: String?
    var artistName: String
    var genre: String?
    var durationListened: TimeInterval
    var trackDuration: TimeInterval
    var wasCompleted: Bool

    init(
        id: UUID = UUID(),
        trackId: String,
        trackTitle: String,
        albumId: String?,
        albumTitle: String?,
        artistId: String?,
        artistName: String,
        genre: String?,
        timestamp: Date = Date(),
        durationListened: TimeInterval,
        trackDuration: TimeInterval,
        wasCompleted: Bool,
        serverId: String
    ) {
        self.id = id
        self.trackId = trackId
        self.trackTitle = trackTitle
        self.albumId = albumId
        self.albumTitle = albumTitle
        self.artistId = artistId
        self.artistName = artistName
        self.genre = genre
        self.timestamp = timestamp
        self.durationListened = durationListened
        self.trackDuration = trackDuration
        self.wasCompleted = wasCompleted
        self.serverId = serverId
    }
}
