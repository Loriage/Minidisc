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
    private(set) var stations: [ArtistStation] = []
    private var favorites = HomeFavorites()
    private var generation = 0
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
        if !forceRefresh, !stations.isEmpty {
            return
        }

        generation += 1
        let request = generation
        isLoading = true
        defer { if request == generation { isLoading = false } }

        // A history outage must not hide stations derived from favorites, and vice versa.
        async let recent = try? libraryService.recentlyPlayedAlbums(size: 35)
        async let frequent = try? libraryService.mostPlayedAlbums(size: 35)
        async let starred = try? (libraryService as? any StarredBrowsing)?.getStarred2()
        let (recentResult, frequentResult, starredResult) = await (recent, frequent, starred)
        guard request == generation, !Task.isCancelled else { return }
        if let recentResult { recentlyPlayed = recentResult }
        if let frequentResult { mostPlayed = frequentResult }
        if let starredResult {
            favorites = HomeFavorites(songs: starredResult.song ?? [], albums: starredResult.album ?? [], artists: starredResult.artist ?? [])
        }
        stations = ArtistStation.suggestions(favorites: favorites, recent: recentlyPlayed, frequent: mostPlayed)
        loadError = recentResult == nil && frequentResult == nil && starredResult == nil ? URLError(.cannotLoadFromNetwork) : nil
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
