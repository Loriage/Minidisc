import Foundation
import SwiftData

/// Per-server, per-device gradient choice. isUserPicked prevents automatic generation
/// from replacing a cover chosen by the user.
@Model
final class PlaylistCoverChoice {
    var playlistId: String
    var serverId: UUID
    var shapeRawValue: String
    var red: Double
    var green: Double
    var blue: Double
    var isUserPicked: Bool
    var updatedAt: Date

    init(
        playlistId: String,
        serverId: UUID,
        spec: PlaylistGradientSpec,
        isUserPicked: Bool,
        updatedAt: Date = Date()
    ) {
        self.playlistId = playlistId
        self.serverId = serverId
        self.shapeRawValue = spec.shape.rawValue
        self.red = spec.red
        self.green = spec.green
        self.blue = spec.blue
        self.isUserPicked = isUserPicked
        self.updatedAt = updatedAt
    }

    /// Rebuilds the frozen spec, or `nil` if the stored form no longer exists (forward-compatible).
    var spec: PlaylistGradientSpec? {
        guard let shape = PlaylistGradientShape(rawValue: shapeRawValue) else { return nil }
        return PlaylistGradientSpec(shape: shape, red: red, green: green, blue: blue)
    }
}
