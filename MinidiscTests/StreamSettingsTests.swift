import Foundation
import Testing
@testable import Minidisc

@Suite("Stream settings")
@MainActor
struct StreamSettingsTests {
    @Test("The active quality follows the app-wide network path")
    func currentQualityFollowsNetworkPath() {
        let suiteName = "test.stream-settings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = StreamSettings(defaults: defaults)
        settings.wifiQuality = .original
        settings.cellularQuality = .mp3_192

        settings.networkPathDidChange(isCellular: false)
        #expect(settings.currentQuality == .original)

        settings.networkPathDidChange(isCellular: true)
        #expect(settings.currentQuality == .mp3_192)
    }

    @Test("Quality choices persist independently")
    func qualityChoicesPersist() {
        let suiteName = "test.stream-settings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = StreamSettings(defaults: defaults)
        settings.wifiQuality = .mp3_320
        settings.cellularQuality = .mp3_192

        let restored = StreamSettings(defaults: defaults)
        #expect(restored.wifiQuality == .mp3_320)
        #expect(restored.cellularQuality == .mp3_192)
    }
}
