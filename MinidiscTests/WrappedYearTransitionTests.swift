import Testing
import Foundation
import SwiftData
@testable import Minidisc

private var ytCal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

private func ytDate(year: Int, month: Int, day: Int) -> Date {
    var c = DateComponents()
    c.year = year; c.month = month; c.day = day; c.hour = 12
    c.timeZone = TimeZone(identifier: "UTC")!
    return Calendar(identifier: .gregorian).date(from: c)!
}

private func ytMakeStats() throws -> StatsService {
    let container = try ModelContainer.minidisc(inMemory: true)
    return StatsService(modelContainer: container)
}

private func ytMakePrefs() -> WrappedPreferences {
    WrappedPreferences(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
}

private func ytMakeService(
    mock: MockPlaylistSyncClient,
    stats: StatsService,
    prefs: WrappedPreferences
) -> WrappedPlaylistService {
    WrappedPlaylistService(clientFactory: { mock }, statsService: stats, preferences: prefs)
}

private func ytMakeEvent(trackId: String, timestamp: Date, serverId: String = "srv") -> PlaybackEventDTO {
    PlaybackEventDTO(
        trackId: trackId,
        trackTitle: "Track \(trackId)",
        albumId: nil,
        albumTitle: nil,
        artistId: nil,
        artistName: "Artist",
        genre: nil,
        timestamp: timestamp,
        durationListened: 200,
        trackDuration: 210,
        wasCompleted: true,
        serverId: serverId
    )
}

@Suite("WrappedPlaylistService Year Transition")
struct WrappedYearTransitionTests {

    @Test func lastYearNil_setsCurrentYear_clearsMonthMarker() async throws {
        let prefs = ytMakePrefs()
        let mock = MockPlaylistSyncClient()
        let stats = try ytMakeStats()
        let service = ytMakeService(mock: mock, stats: stats, prefs: prefs)

        prefs.setLastUpdatedMonth(YearMonth(year: 2026, month: 3), serverId: "srv")
        #expect(prefs.lastWrappedYear(serverId: "srv") == nil)

        await service.handleYearTransitionIfNeeded(
            serverId: "srv", calendar: ytCal, currentDate: ytDate(year: 2026, month: 5, day: 4)
        )

        #expect(prefs.lastWrappedYear(serverId: "srv") == 2026)
        #expect(prefs.lastUpdatedMonth(serverId: "srv") == nil)
    }

    @Test func lastYear2025_current2026_updatesYear_clearsMonthMarker() async throws {
        let prefs = ytMakePrefs()
        let mock = MockPlaylistSyncClient()
        let stats = try ytMakeStats()
        let service = ytMakeService(mock: mock, stats: stats, prefs: prefs)

        prefs.setLastWrappedYear(2025, serverId: "srv")
        prefs.setLastUpdatedMonth(YearMonth(year: 2025, month: 11), serverId: "srv")

        await service.handleYearTransitionIfNeeded(
            serverId: "srv", calendar: ytCal, currentDate: ytDate(year: 2026, month: 1, day: 10)
        )

        #expect(prefs.lastWrappedYear(serverId: "srv") == 2026)
        #expect(prefs.lastUpdatedMonth(serverId: "srv") == nil)
    }

    @Test func lastYear2026_current2026_isNoOp_monthMarkerUnchanged() async throws {
        let prefs = ytMakePrefs()
        let mock = MockPlaylistSyncClient()
        let stats = try ytMakeStats()
        let service = ytMakeService(mock: mock, stats: stats, prefs: prefs)

        prefs.setLastWrappedYear(2026, serverId: "srv")
        prefs.setLastUpdatedMonth(YearMonth(year: 2026, month: 4), serverId: "srv")

        await service.handleYearTransitionIfNeeded(
            serverId: "srv", calendar: ytCal, currentDate: ytDate(year: 2026, month: 6, day: 1)
        )

        #expect(prefs.lastWrappedYear(serverId: "srv") == 2026)
        #expect(prefs.lastUpdatedMonth(serverId: "srv") == YearMonth(year: 2026, month: 4))
    }

    @Test func yearBascule_decUsesCurrentYearPlaylist_janCreatesNextYear() async throws {
        let mock = MockPlaylistSyncClient()
        let stats = try ytMakeStats()
        let prefs = ytMakePrefs()
        let service = ytMakeService(mock: mock, stats: stats, prefs: prefs)

        await stats.recordPlayback(ytMakeEvent(trackId: "dec-t", timestamp: ytDate(year: 2025, month: 12, day: 15)))
        await stats.recordPlayback(ytMakeEvent(trackId: "jan-t", timestamp: ytDate(year: 2026, month: 1, day: 15)))

        let resultDec = await service.runYearlyPlaylistSyncIfNeeded(
            serverId: "srv", calendar: ytCal, currentDate: ytDate(year: 2025, month: 12, day: 15)
        )
        #expect(resultDec == .updated(tracksCount: 1))

        let idAfterDec = prefs.playlistId(year: 2025, serverId: "srv")
        #expect(idAfterDec != nil)

        await service.handleYearTransitionIfNeeded(
            serverId: "srv", calendar: ytCal, currentDate: ytDate(year: 2026, month: 1, day: 1)
        )
        #expect(prefs.lastWrappedYear(serverId: "srv") == 2026)
        #expect(prefs.lastUpdatedMonth(serverId: "srv") == nil)

        let resultJan = await service.runYearlyPlaylistSyncIfNeeded(
            serverId: "srv", calendar: ytCal, currentDate: ytDate(year: 2026, month: 1, day: 15)
        )
        #expect(resultJan == .updated(tracksCount: 1))

        let idAfterJan = prefs.playlistId(year: 2026, serverId: "srv")
        #expect(idAfterJan != nil)
        #expect(idAfterJan != idAfterDec)

        let creates = await mock.createPlaylistCalls
        // 4 calls: create-2025, replace-2025, create-2026, replace-2026
        #expect(creates.count == 4)
        let createCalls = creates.filter { $0.playlistId == nil }
        #expect(createCalls.count == 2)
        #expect(createCalls[0].name == "Minidisc Wrapped 2025")
        #expect(createCalls[1].name == "Minidisc Wrapped 2026")

        let replaceCalls = creates.filter { $0.playlistId != nil }
        #expect(replaceCalls.count == 2)
        #expect(replaceCalls[0].songIds == ["dec-t"])
        #expect(replaceCalls[1].songIds == ["jan-t"])
    }
}

@Suite("WrappedPreferences")
struct WrappedPreferencesTests {

    @Test func lastUpdatedMonth_roundTrip() {
        let prefs = ytMakePrefs()
        let ym = YearMonth(year: 2026, month: 4)

        #expect(prefs.lastUpdatedMonth(serverId: "srv") == nil)

        prefs.setLastUpdatedMonth(ym, serverId: "srv")
        #expect(prefs.lastUpdatedMonth(serverId: "srv") == ym)
    }

    @Test func playlistId_roundTrip() {
        let prefs = ytMakePrefs()

        #expect(prefs.playlistId(year: 2026, serverId: "srv") == nil)

        prefs.setPlaylistId("pl-abc", year: 2026, serverId: "srv")
        #expect(prefs.playlistId(year: 2026, serverId: "srv") == "pl-abc")
    }

    @Test func lastWrappedYear_roundTrip() {
        let prefs = ytMakePrefs()

        #expect(prefs.lastWrappedYear(serverId: "srv") == nil)

        prefs.setLastWrappedYear(2026, serverId: "srv")
        #expect(prefs.lastWrappedYear(serverId: "srv") == 2026)
    }

    @Test func multiServer_keysAreIsolated() {
        let prefs = ytMakePrefs()

        prefs.setLastUpdatedMonth(YearMonth(year: 2026, month: 3), serverId: "srvA")
        prefs.setPlaylistId("pl-A", year: 2026, serverId: "srvA")
        prefs.setLastWrappedYear(2026, serverId: "srvA")

        #expect(prefs.lastUpdatedMonth(serverId: "srvB") == nil)
        #expect(prefs.playlistId(year: 2026, serverId: "srvB") == nil)
        #expect(prefs.lastWrappedYear(serverId: "srvB") == nil)

        #expect(prefs.lastUpdatedMonth(serverId: "srvA") == YearMonth(year: 2026, month: 3))
        #expect(prefs.playlistId(year: 2026, serverId: "srvA") == "pl-A")
        #expect(prefs.lastWrappedYear(serverId: "srvA") == 2026)
    }
}
