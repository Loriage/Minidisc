import Testing
import Foundation
import SwiftSonic
@testable import Minidisc

// MARK: - Mock provider

private struct DVMockProvider: RecommendationProvider {
    let releases: [AlbumRecommendation]
    let shouldThrow: Bool

    init(releases: [AlbumRecommendation] = [], shouldThrow: Bool = false) {
        self.releases = releases
        self.shouldThrow = shouldThrow
    }

    func freshReleases(limit: Int, daysWindow: Int) async throws -> [AlbumRecommendation] {
        if shouldThrow { throw URLError(.notConnectedToInternet) }
        return Array(releases.prefix(limit))
    }

    func similarArtists(toArtistID: String, limit: Int) async throws -> [SimilarArtistRecommendation] { [] }
}

// MARK: - Capturing provider (records params for assertion)

@MainActor
private final class DVCapturingProvider: RecommendationProvider {
    private(set) var capturedLimit: Int?
    private(set) var capturedDaysWindow: Int?

    func freshReleases(limit: Int, daysWindow: Int) async throws -> [AlbumRecommendation] {
        capturedLimit = limit
        capturedDaysWindow = daysWindow
        return []
    }
}

// MARK: - Library stub (never called in fresh releases tests)

@MainActor
private final class DVLibraryStub: ListeningHistoryBrowsing {
    func recentlyPlayedAlbums(size: Int) async throws -> [AlbumID3] { throw URLError(.unknown) }
    func mostPlayedAlbums(size: Int) async throws -> [AlbumID3] { throw URLError(.unknown) }
}

private func dvCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
    return calendar
}

private func dvDate(year: Int, month: Int, day: Int) -> Date {
    dvCalendar().date(from: DateComponents(year: year, month: month, day: day)) ?? .distantPast
}

// MARK: - Tests

@Suite("DiscoverViewModel — fresh releases")
@MainActor
struct DiscoverViewModelFreshReleasesTests {

    private func makeVM(
        releases: [AlbumRecommendation] = [],
        shouldThrow: Bool = false,
        referenceDate: Date = dvDate(year: 2026, month: 5, day: 25)
    ) -> DiscoverViewModel {
        let provider = DVMockProvider(releases: releases, shouldThrow: shouldThrow)
        let service = RecommendationService(providers: [provider])
        return DiscoverViewModel(
            libraryService: DVLibraryStub(),
            recommendationService: service,
            calendar: dvCalendar(),
            now: { referenceDate }
        )
    }

    @Test("happy path: provider results are stored in freshReleases")
    func happyPath() async {
        let releases = [
            AlbumRecommendation(id: "mbid-1", title: "Test Album", artistName: "Test Artist",
                                releaseDate: dvDate(year: 2026, month: 5, day: 10),
                                coverArtURL: nil, inLibrary: false)
        ]
        let vm = makeVM(releases: releases)
        await vm.loadFreshReleases()
        #expect(vm.freshReleases == releases)
    }

    @Test("empty provider: freshReleases stays empty")
    func emptyProvider() async {
        let vm = makeVM(releases: [])
        await vm.loadFreshReleases()
        #expect(vm.freshReleases.isEmpty)
    }

    @Test("throwing provider: no rethrow, freshReleases stays empty")
    func throwingProviderNoRethrow() async {
        let vm = makeVM(shouldThrow: true)
        await vm.loadFreshReleases()
        #expect(vm.freshReleases.isEmpty)
    }

    @Test("isLoadingFreshReleases starts false and resets to false after load")
    func loadingFlagResets() async {
        let vm = makeVM()
        #expect(!vm.isLoadingFreshReleases)
        await vm.loadFreshReleases()
        #expect(!vm.isLoadingFreshReleases)
    }

    @Test("all releases from the current month are kept without a ten-item cap")
    func currentMonthIsNotCappedAt10() async {
        let manyReleases = (0..<20).map {
            AlbumRecommendation(id: "id-\($0)", title: "Album \($0)", artistName: "Artist",
                                releaseDate: dvDate(year: 2026, month: 5, day: ($0 % 25) + 1),
                                coverArtURL: nil, inLibrary: false)
        }
        let vm = makeVM(releases: manyReleases)
        await vm.loadFreshReleases()
        #expect(vm.freshReleases.count == 20)
    }

    @Test("only releases in the current calendar month are kept")
    func filtersToCurrentCalendarMonth() async {
        let releases = [
            AlbumRecommendation(id: "previous", title: "Previous", artistName: "Artist",
                                releaseDate: dvDate(year: 2026, month: 4, day: 30), coverArtURL: nil, inLibrary: false),
            AlbumRecommendation(id: "current", title: "Current", artistName: "Artist",
                                releaseDate: dvDate(year: 2026, month: 5, day: 1), coverArtURL: nil, inLibrary: false),
            AlbumRecommendation(id: "future", title: "Future", artistName: "Artist",
                                releaseDate: dvDate(year: 2026, month: 6, day: 1), coverArtURL: nil, inLibrary: false),
            AlbumRecommendation(id: "unknown", title: "Unknown", artistName: "Artist",
                                releaseDate: nil, coverArtURL: nil, inLibrary: false),
        ]
        let vm = makeVM(releases: releases)

        await vm.loadFreshReleases()

        #expect(vm.freshReleases.compactMap(\.id) == ["current"])
    }

    @Test("VM requests the elapsed current-month window without truncating results")
    func requestsCurrentMonthWindow() async {
        let capturing = DVCapturingProvider()
        let service = RecommendationService(providers: [capturing])
        let referenceDate = dvDate(year: 2026, month: 5, day: 25)
        let vm = DiscoverViewModel(
            libraryService: DVLibraryStub(),
            recommendationService: service,
            calendar: dvCalendar(),
            now: { referenceDate }
        )
        await vm.loadFreshReleases()
        let limit = capturing.capturedLimit
        let window = capturing.capturedDaysWindow
        #expect(limit == Int.max)
        #expect(window == 25)
    }

    @Test("releases sorted by releaseDate descending after load")
    func sortedByDateDescending() async {
        let may10 = dvDate(year: 2026, month: 5, day: 10)
        let may1 = dvDate(year: 2026, month: 5, day: 1)
        let may20 = dvDate(year: 2026, month: 5, day: 20)
        let releases = [
            AlbumRecommendation(id: "a", title: "A", artistName: "X", releaseDate: may10, coverArtURL: nil, inLibrary: false),
            AlbumRecommendation(id: "b", title: "B", artistName: "X", releaseDate: may1,  coverArtURL: nil, inLibrary: false),
            AlbumRecommendation(id: "c", title: "C", artistName: "X", releaseDate: may20, coverArtURL: nil, inLibrary: false),
        ]
        let vm = makeVM(releases: releases)
        await vm.loadFreshReleases()
        let ids = vm.freshReleases.compactMap { $0.id }
        #expect(ids == ["c", "a", "b"], "Expected newest first: c(may-20), a(may-10), b(may-1)")
    }
}
