import Foundation
import Testing
@testable import Minidisc

@MainActor
@Suite("PlaylistCoverChoice")
struct PlaylistCoverChoiceTests {
    @Test("A frozen gradient round-trips through the persisted scalar fields")
    func frozenGradientRoundTrip() {
        let source = PlaylistGradientSpec(
            shape: .radialGlow,
            red: 0.125,
            green: 0.5,
            blue: 0.875
        )
        let serverId = UUID()
        let updatedAt = Date(timeIntervalSince1970: 1_711_111_111)

        let choice = PlaylistCoverChoice(
            playlistId: "playlist-1",
            serverId: serverId,
            spec: source,
            isUserPicked: true,
            updatedAt: updatedAt
        )

        #expect(choice.playlistId == "playlist-1")
        #expect(choice.serverId == serverId)
        #expect(choice.shapeRawValue == PlaylistGradientShape.radialGlow.rawValue)
        #expect(choice.red == source.red)
        #expect(choice.green == source.green)
        #expect(choice.blue == source.blue)
        #expect(choice.isUserPicked)
        #expect(choice.updatedAt == updatedAt)
        #expect(choice.spec == source)
    }

    @Test("An unknown future shape does not produce an invalid gradient")
    func unknownShapeReturnsNil() {
        let choice = PlaylistCoverChoice(
            playlistId: "playlist-1",
            serverId: UUID(),
            spec: PlaylistGradientSpec(shape: .prism, red: 0.1, green: 0.2, blue: 0.3),
            isUserPicked: false
        )

        choice.shapeRawValue = "future-gradient-shape"

        #expect(choice.spec == nil)
    }
}
