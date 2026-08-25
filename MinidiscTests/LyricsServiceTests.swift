import Testing
import Foundation
import SwiftData
import SwiftSonic
@testable import Minidisc

// MARK: - Minimal mock for LyricsService construction

@MainActor
final class MockLyricsServerService: ServerServiceProtocol {
    let state: ServerState = ServerState()
    func addServer(displayName: String, baseURL: String, username: String, password: String, customHeaders: [String: String]) async throws {}
    func removeServer(id: UUID) async throws {}
    func setActiveServer(id: UUID) async throws {}
    func updateCustomHeaders(_ headers: [String: String], forServer id: UUID) async throws {}
    func updateServer(id: UUID, displayName: String, baseURL: String, username: String, password: String, customHeaders: [String: String]) async throws {}
    func setAudioMuseConfig(serverId: UUID, urlString: String?, token: String?) async throws {}
    func testConnection() async throws {}
    func testConnection(url: String, username: String, password: String, customHeaders: [String: String]) async throws {}
    func activeConnectionVersion() async -> ServerConnection.Version? { nil }
    func activeConnection() async throws -> ServerConnection { throw MinidiscError.notImplemented }
    func loadPersistedState() async {}
}

actor RecordingLRCLIBFetcher: LRCLIBLyricsFetching {
    private let record: LRCLIBLyricsRecord?
    private let failure: LyricsError
    private(set) var requests: [LRCLIBTrackSignature] = []

    init(record: LRCLIBLyricsRecord? = nil, failure: LyricsError = .notFound) {
        self.record = record
        self.failure = failure
    }

    func lyrics(for signature: LRCLIBTrackSignature) async throws -> LRCLIBLyricsRecord {
        requests.append(signature)
        guard let record else { throw failure }
        return record
    }
}

// MARK: - Helpers

@MainActor
private func makeService(
    lrclibFetcher: any LRCLIBLyricsFetching = RecordingLRCLIBFetcher()
) throws -> (LyricsService, ModelContainer) {
    let container = try ModelContainer(
        for: Schema([CachedLyrics.self]),
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    let mock = MockLyricsServerService()
    let service = LyricsService(
        serverService: mock,
        modelContainer: container,
        lrclibClient: lrclibFetcher
    )
    return (service, container)
}

private func sampleTrack(id: String = "song-xyz") -> DisplayableSong {
    DisplayableSong(
        id: id,
        title: "Run Boy Run",
        artist: "Woodkid",
        albumId: "album-1",
        albumName: "The Golden Age",
        artistId: "artist-1",
        genre: "Alternative",
        duration: 213.42,
        trackNumber: 1,
        isDownloaded: false,
        coverArtId: "cover-1",
        audioFormat: "FLAC",
        replayGainTrackGain: nil,
        replayGainTrackPeak: nil,
        replayGainAlbumGain: nil,
        replayGainAlbumPeak: nil,
        replayGainBaseGain: nil,
        replayGainFallbackGain: nil
    )
}

private func lrclibRecord(
    plainLyrics: String? = "Run boy run",
    syncedLyrics: String? = "[00:01.25]Run boy run"
) -> LRCLIBLyricsRecord {
    LRCLIBLyricsRecord(
        id: 42,
        trackName: "Run Boy Run",
        artistName: "Woodkid",
        albumName: "The Golden Age",
        duration: 213.42,
        instrumental: false,
        plainLyrics: plainLyrics,
        syncedLyrics: syncedLyrics
    )
}

private func sampleList() -> LyricsList {
    LyricsList(structuredLyrics: [
        StructuredLyrics(lang: "en", synced: true, line: [Line(value: "Hello", start: 0)]),
        StructuredLyrics(lang: "fr", synced: false, line: [Line(value: "Bonjour")])
    ])
}

// MARK: - selectBestLanguage

@Suite("LyricsService — selectBestLanguage")
@MainActor
struct LyricsSelectBestLanguageTests {

    @Test func emptyList_returnsNil() throws {
        let (service, _) = try makeService()
        let result = service.selectBestLanguage(from: LyricsList(structuredLyrics: []))
        #expect(result == nil)
    }

    @Test func preferred_syncedVariantChosen() throws {
        let list = LyricsList(structuredLyrics: [
            StructuredLyrics(lang: "fr", synced: false, line: []),
            StructuredLyrics(lang: "fr", synced: true, line: [])
        ])
        let (service, _) = try makeService()
        let result = service.selectBestLanguage(from: list, preferred: "fr")
        #expect(result?.synced == true)
    }

    @Test func preferred_unsyncedFallback_whenNoSynced() throws {
        let list = LyricsList(structuredLyrics: [
            StructuredLyrics(lang: "fr", synced: false, line: [])
        ])
        let (service, _) = try makeService()
        let result = service.selectBestLanguage(from: list, preferred: "fr")
        #expect(result?.lang == "fr")
        #expect(result?.synced == false)
    }

    @Test func locale_frFR_picksFrenchUnsynced_overEnglishSynced() throws {
        let (service, _) = try makeService()
        let result = service.selectBestLanguage(from: sampleList(), locale: Locale(identifier: "fr_FR"))
        #expect(result?.lang == "fr")
    }

    @Test func locale_enUS_picksSyncedEnglish() throws {
        let (service, _) = try makeService()
        let result = service.selectBestLanguage(from: sampleList(), locale: Locale(identifier: "en_US"))
        #expect(result?.lang == "en")
        #expect(result?.synced == true)
    }

    @Test func noLocaleMatch_returnFirstSynced() throws {
        let list = LyricsList(structuredLyrics: [
            StructuredLyrics(lang: "ja", synced: false, line: []),
            StructuredLyrics(lang: "ko", synced: true, line: [])
        ])
        let (service, _) = try makeService()
        let result = service.selectBestLanguage(from: list, locale: Locale(identifier: "fr_FR"))
        #expect(result?.lang == "ko")
        #expect(result?.synced == true)
    }

    @Test func xxx_normalizedToUnd() throws {
        let list = LyricsList(structuredLyrics: [
            StructuredLyrics(lang: "xxx", synced: true, line: [])
        ])
        let (service, _) = try makeService()
        let result = service.selectBestLanguage(from: list, preferred: "und")
        #expect(result?.synced == true)
    }
}

// MARK: - Cache hit

@Suite("LyricsService — cache")
@MainActor
struct LyricsCacheTests {

    @Test func cacheHit_returnsWithoutNetwork() async throws {
        let (service, container) = try makeService()
        let serverId = UUID()
        let track = sampleTrack()
        let list = sampleList()

        // Pre-populate cache directly via ModelContext
        let data = try JSONEncoder().encode(list)
        await MainActor.run {
            let ctx = ModelContext(container)
            ctx.insert(CachedLyrics(songId: track.id, serverId: serverId, jsonPayload: data))
            try? ctx.save()
        }

        // fetchLyrics should return from cache; MockLyricsServerService throws on makeSwiftSonicClient
        let result = try await service.fetchLyrics(
            for: track,
            serverId: serverId,
            source: .navidrome
        )
        #expect(result == list)
    }
}

// MARK: - Source routing

@Suite("LyricsService — source routing")
@MainActor
struct LyricsSourceRoutingTests {
    @Test func lrclibOnlyMapsSyncedAndPlainLyrics() async throws {
        let fetcher = RecordingLRCLIBFetcher(record: lrclibRecord())
        let (service, _) = try makeService(lrclibFetcher: fetcher)
        let track = sampleTrack()

        let result = try await service.fetchLyrics(
            for: track,
            serverId: UUID(),
            source: .lrclib
        )

        let synced = try #require(result.structuredLyrics.first(where: { $0.synced }))
        #expect(synced.line.first?.value == "Run boy run")
        #expect(synced.line.first?.start == 1_250)
        #expect(result.structuredLyrics.contains(where: { !$0.synced }))

        let requests = await fetcher.requests
        let request = try #require(requests.first)
        #expect(request.title == track.title)
        #expect(request.artist == track.artist)
        #expect(request.album == track.albumName)
        #expect(request.duration == track.duration)
    }

    @Test func autoFallsBackToLRCLIBWhenNavidromeFails() async throws {
        let fetcher = RecordingLRCLIBFetcher(record: lrclibRecord(plainLyrics: "Fallback", syncedLyrics: nil))
        let (service, _) = try makeService(lrclibFetcher: fetcher)

        let result = try await service.fetchLyrics(
            for: sampleTrack(),
            serverId: UUID(),
            source: .automatic
        )

        #expect(result.structuredLyrics.first?.line.first?.value == "Fallback")
        let requests = await fetcher.requests
        #expect(requests.count == 1)
    }

    @Test func navidromeOnlyNeverContactsLRCLIB() async throws {
        let fetcher = RecordingLRCLIBFetcher(record: lrclibRecord())
        let (service, _) = try makeService(lrclibFetcher: fetcher)

        await #expect(throws: (any Error).self) {
            try await service.fetchLyrics(
                for: sampleTrack(),
                serverId: UUID(),
                source: .navidrome
            )
        }
        let requests = await fetcher.requests
        #expect(requests.isEmpty)
    }

    @Test func providerCachesRemainIndependent() async throws {
        let fetcher = RecordingLRCLIBFetcher(record: lrclibRecord(plainLyrics: "From LRCLIB", syncedLyrics: nil))
        let (service, container) = try makeService(lrclibFetcher: fetcher)
        let serverId = UUID()
        let track = sampleTrack()
        let navidromeList = sampleList()
        let data = try JSONEncoder().encode(navidromeList)
        let context = ModelContext(container)
        context.insert(CachedLyrics(
            songId: track.id,
            serverId: serverId,
            jsonPayload: data,
            provider: .navidrome
        ))
        try context.save()

        let lrclibList = try await service.fetchLyrics(
            for: track,
            serverId: serverId,
            source: .lrclib
        )

        #expect(lrclibList != navidromeList)
        #expect(lrclibList.structuredLyrics.first?.line.first?.value == "From LRCLIB")
        let requests = await fetcher.requests
        #expect(requests.count == 1)
    }
}
