import Observation
import OSLog
import SwiftSonic

@Observable
@MainActor
final class SongsListViewModel {
    /// The sorted, display-ready list — populated once loading finishes (or when the sort changes).
    private(set) var displaySongs: [DisplayableSong] = []
    /// Live count while paging, for the progress indicator.
    private(set) var loadedCount = 0
    /// True while pages are still being fetched.
    private(set) var isLoading = false
    /// True if the safety cap was hit (server has more songs than we loaded) — surfaced to the user.
    private(set) var didTruncate = false
    var error: UserFacingError?

    private var rawSongs: [Song] = []
    private var currentSort: SongSort = .title
    private let libraryService: any SongBrowsing

    /// 1000/page keeps the number of round-trips low while staying responsive. The cap is only a backstop
    /// against a server that ignores `songOffset` (metadata is light, so memory isn't the limit).
    private static let pageSize = 1000
    private static let safetyCap = 200_000

    init(libraryService: any SongBrowsing) {
        self.libraryService = libraryService
    }

    /// Pages the whole library (server order), updating `loadedCount` as it goes, then sorts off-main.
    func load(sort: SongSort) async {
        currentSort = sort
        rawSongs = []
        displaySongs = []
        loadedCount = 0
        didTruncate = false
        error = nil
        isLoading = true
        defer { isLoading = false }

        var offset = 0
        var seen = Set<String>()
        do {
            while rawSongs.count < Self.safetyCap {
                let page = try await libraryService.allSongs(offset: offset, count: Self.pageSize)
                if page.isEmpty { break }
                // No-progress guard: if a full page adds no new ids, the server is ignoring the offset —
                // stop instead of looping forever.
                let fresh = page.filter { seen.insert($0.id).inserted }
                if fresh.isEmpty { break }
                rawSongs.append(contentsOf: fresh)
                loadedCount = rawSongs.count
                if page.count < Self.pageSize { break } // last (short) page
                offset += Self.pageSize
            }
            if rawSongs.count >= Self.safetyCap { didTruncate = true }
            Logger.library.info("All Songs loaded \(self.rawSongs.count, privacy: .public) songs (truncated=\(self.didTruncate, privacy: .public))")
        } catch {
            Logger.library.error("All Songs load failed: \(error, privacy: .public)")
            self.error = UserFacingError.from(error)
        }
        await recomputeDisplay()
    }

    /// Re-sorts the already-loaded songs (no network) when the user changes the sort.
    func changeSort(_ sort: SongSort) async {
        guard sort != currentSort else { return }
        currentSort = sort
        await recomputeDisplay()
    }

    /// Sorts + maps off the main actor so large libraries never hitch the UI.
    private func recomputeDisplay() async {
        let raw = rawSongs
        let sort = currentSort
        displaySongs = await Self.sortedDisplaySongs(raw, sort: sort)
    }

    @concurrent
    private static func sortedDisplaySongs(_ songs: [Song], sort: SongSort) async -> [DisplayableSong] {
        sort.sorted(songs).map { DisplayableSong(from: $0) }
    }
}
