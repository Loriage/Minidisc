import Foundation
import Testing
@testable import Minidisc

@Suite("Stream settings")
@MainActor
struct StreamSettingsTests {
    @Test("The active quality follows the app-wide network path", arguments: [StreamQuality.mp3_192, .opus_128, .opus_192])
    func currentQualityFollowsNetworkPath(cellularQuality: StreamQuality) {
        let suiteName = "test.stream-settings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = StreamSettings(defaults: defaults)
        settings.wifiQuality = .original
        settings.cellularQuality = cellularQuality

        settings.networkPathDidChange(isCellular: false)
        #expect(settings.currentQuality == .original)

        settings.networkPathDidChange(isCellular: true)
        #expect(settings.currentQuality == cellularQuality)

        settings.networkPathDidChange(isCellular: false)
        #expect(settings.currentQuality == .original)
    }

    @Test("Quality choices persist independently", arguments: [StreamQuality.mp3_192, .opus_128, .opus_192])
    func qualityChoicesPersist(cellularQuality: StreamQuality) {
        let suiteName = "test.stream-settings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = StreamSettings(defaults: defaults)
        settings.wifiQuality = .mp3_320
        settings.cellularQuality = cellularQuality

        let restored = StreamSettings(defaults: defaults)
        #expect(restored.wifiQuality == .mp3_320)
        #expect(restored.cellularQuality == cellularQuality)
    }
}
