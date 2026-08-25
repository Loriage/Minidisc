import Foundation
import Testing
@testable import Minidisc

@MainActor
private final class SettingsKeychain: KeychainServiceProtocol {
    private var storage: [String: Data] = [:]

    func store<T: Codable & Sendable>(_ value: T, forKey key: String) async throws {
        storage[key] = try JSONEncoder().encode(value)
    }

    func retrieve<T: Codable & Sendable>(_ type: T.Type, forKey key: String) async throws -> T? {
        guard let data = storage[key] else { return nil }
        return try JSONDecoder().decode(type, from: data)
    }

    func delete(forKey key: String) async throws {
        storage[key] = nil
    }
}

@Suite("Domain settings persistence")
@MainActor
struct DomainSettingsPersistenceTests {
    @Test("ReplayGain and crossfade use the injected defaults suite")
    func playbackSettingsUseInjectedDefaults() {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let replayGain = ReplayGainSettings(defaults: defaults)
        replayGain.enabled = true
        replayGain.mode = .album
        replayGain.preAmp = 30
        replayGain.preventClipping = false

        let crossfade = CrossfadeSettings(defaults: defaults)
        crossfade.duration = 5.5
        crossfade.disableForGapless = false

        let restoredReplayGain = ReplayGainSettings(defaults: defaults)
        #expect(restoredReplayGain.enabled)
        #expect(restoredReplayGain.mode == .album)
        #expect(restoredReplayGain.preAmp == ReplayGainSettings.maxPreAmp)
        #expect(!restoredReplayGain.preventClipping)

        let restoredCrossfade = CrossfadeSettings(defaults: defaults)
        #expect(restoredCrossfade.duration == 5.5)
        #expect(!restoredCrossfade.disableForGapless)
    }

    @Test("the legacy track-count cache preference migrates to a byte capacity")
    func cacheCapacityMigration() {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(4, forKey: "minidisc.cache.maxTracks")

        let settings = CacheSettings(defaults: defaults)
        #expect(settings.capacityMegabytes == 256)
        #expect(settings.capacityBytes == 256 * 1_000_000)

        settings.capacityMegabytes = 1_000
        #expect(CacheSettings(defaults: defaults).capacityMegabytes == 1_024)
    }

    @Test("Lidarr keeps its URL in the injected defaults suite")
    func lidarrUsesInjectedDefaults() async throws {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let keychain = SettingsKeychain()
        let settings = LidarrSettings(keychain: keychain, defaults: defaults)

        try await settings.connect(
            baseURL: "  https://lidarr.example.com  ",
            apiKey: "public-test-value",
            headers: [:]
        )

        let restored = LidarrSettings(keychain: keychain, defaults: defaults)
        await restored.loadPersistedState()
        #expect(restored.baseURL == "https://lidarr.example.com")
        #expect(restored.isConnected)

        await restored.disconnect()
        #expect(LidarrSettings(keychain: keychain, defaults: defaults).baseURL.isEmpty)
    }

    private func isolatedDefaults() -> (UserDefaults, String) {
        let suiteName = "app.minidisc.tests.settings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
