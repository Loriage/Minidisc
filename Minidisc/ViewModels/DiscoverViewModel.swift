import Foundation
import SwiftSonic
import OSLog

@Observable
@MainActor
final class DiscoverViewModel {
    private let libraryService: any ListeningHistoryBrowsing
    private let recommendationService: RecommendationService
    private let calendar: Calendar
    private let now: @Sendable () -> Date

    // MARK: - State

    private(set) var recentlyPlayed: [AlbumID3] = []
    private(set) var mostPlayed: [AlbumID3] = []
    private(set) var isLoading: Bool = false
    private(set) var loadError: Error?
    private(set) var freshReleases: [AlbumRecommendation] = []
    private(set) var isLoadingFreshReleases: Bool = false

    init(
        libraryService: any ListeningHistoryBrowsing,
        recommendationService: RecommendationService,
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.libraryService = libraryService
        self.recommendationService = recommendationService
        self.calendar = calendar
        self.now = now
    }

    // MARK: - Derived state

    /// True when the initial fetch is in progress and we have nothing to show yet.
    var isInitialLoading: Bool {
        isLoading && recentlyPlayed.isEmpty && mostPlayed.isEmpty
    }

    /// True when load failed and we have nothing to show.
    var isErrorState: Bool {
        loadError != nil && recentlyPlayed.isEmpty && mostPlayed.isEmpty
    }

    // MARK: - Loading

    func load(forceRefresh: Bool = false) async {
        if !forceRefresh, !recentlyPlayed.isEmpty, !mostPlayed.isEmpty {
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            async let recent = libraryService.recentlyPlayedAlbums(size: 35)
            async let frequent = libraryService.mostPlayedAlbums(size: 35)
            let (recentResult, frequentResult) = try await (recent, frequent)
            self.recentlyPlayed = recentResult
            self.mostPlayed = frequentResult
            self.loadError = nil
        } catch {
            self.loadError = error
            Logger.discover.error("Failed to load Discover sections: \(error, privacy: .public)")
        }
    }

    func loadFreshReleases() async {
        isLoadingFreshReleases = true
        defer { isLoadingFreshReleases = false }

        let referenceDate = now()
        guard let currentMonth = calendar.dateInterval(of: .month, for: referenceDate) else {
            freshReleases = []
            return
        }
        let elapsedDays = calendar.dateComponents(
            [.day],
            from: currentMonth.start,
            to: referenceDate
        ).day ?? 0

        do {
            let fetched = try await recommendationService.freshReleases(
                limit: .max,
                daysWindow: max(1, elapsedDays + 1)
            )
            freshReleases = fetched
                .filter { release in
                    guard let releaseDate = release.releaseDate else { return false }
                    return releaseDate >= currentMonth.start && releaseDate < currentMonth.end
                }
                .sorted {
                    ($0.releaseDate ?? .distantPast) > ($1.releaseDate ?? .distantPast)
                }
        } catch {
            Logger.discover.error("Failed to load fresh releases: \(error, privacy: .public)")
        }
    }
}
