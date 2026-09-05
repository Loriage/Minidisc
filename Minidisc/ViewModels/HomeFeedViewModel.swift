import Foundation
import Observation
import SwiftSonic

@Observable
@MainActor
final class HomeFeedViewModel {
    nonisolated struct GenreShelf: Identifiable, Sendable, Codable {
        let name: String
        let albums: [AlbumID3]
        var id: String { name }
    }

    nonisolated enum Section: Hashable, Sendable { case playlists, history, recent, genres, favorites, habits }
    private nonisolated enum SectionResult: Sendable {
        case playlists([Playlist])
        case history([AlbumID3])
        case recent([AlbumID3])
        case genres([GenreShelf])
        case favorites(HomeFavorites)
        case habits([AlbumID3])
        case failure(Section, UserFacingError)
        case cancelled(Section)

        var section: Section {
            switch self {
            case .playlists: .playlists
            case .history: .history
            case .recent: .recent
            case .genres: .genres
            case .favorites: .favorites
            case .habits: .habits
            case .failure(let section, _), .cancelled(let section): section
            }
        }
    }

    private(set) var topPicks: [Playlist] = []
    private(set) var recentlyPlayed: [AlbumID3] = []
    private(set) var recentlyAdded: [AlbumID3] = []
    private(set) var genreShelves: [GenreShelf] = []
    private(set) var favorites = HomeFavorites()
    private(set) var mostPlayed: [AlbumID3] = []
    var heavyRotation: [AlbumID3] {
        Array(HomePersonalization.unique(mostPlayed, excluding: Set((recentlyPlayed + favorites.albums).map(\.id))).prefix(12))
    }
    var rediscovery: [AlbumID3] {
        HomePersonalization.rediscovery(favorites: [], frequent: mostPlayed,
                                        recent: recentlyPlayed + favorites.albums + heavyRotation)
    }
    var relevantAdditions: [AlbumID3] {
        HomePersonalization.relevantAdditions(recentlyAdded, favorites: favorites, frequent: mostPlayed)
    }
    var otherAdditions: [AlbumID3] {
        HomePersonalization.unique(recentlyAdded, excluding: Set(relevantAdditions.map(\.id)))
    }
    private(set) var pendingSections: Set<Section> = []
    private(set) var hasPartialFailure = false
    var isLoading = false
    var error: UserFacingError?
    var isEmpty: Bool { topPicks.isEmpty && recentlyPlayed.isEmpty && recentlyAdded.isEmpty && genreShelves.isEmpty && favorites.songs.isEmpty && favorites.albums.isEmpty && mostPlayed.isEmpty }

    private let libraryService: any PlaylistBrowsing & RecentlyAddedAlbumBrowsing & ListeningHistoryBrowsing & GenreBrowsing
    private let cache: HomeFeedCache?
    private let serverID: UUID?
    private let diagnostics: PlaybackDiagnostics?
    private var generation: UInt64 = 0

    init(
        libraryService: any PlaylistBrowsing & RecentlyAddedAlbumBrowsing & ListeningHistoryBrowsing & GenreBrowsing,
        cache: HomeFeedCache? = nil,
        serverID: UUID? = nil,
        diagnostics: PlaybackDiagnostics? = nil
    ) {
        self.libraryService = libraryService
        self.cache = cache
        self.serverID = serverID
        self.diagnostics = diagnostics
    }

    func load(isOnline: Bool = true, preserveLayout: Bool = false) async {
        let startedAt = Date()
        var measuredContent = !isEmpty
        generation &+= 1
        let request = generation
        isLoading = true
        error = nil
        hasPartialFailure = false
        defer {
            if request == generation { isLoading = false; pendingSections = [] }
        }
        if isEmpty, let cache, let serverID, let saved = await cache.load(serverID: serverID) {
            guard request == generation, !Task.isCancelled else { return }
            apply(saved)
            if !isEmpty {
                diagnostics?.recordHomeContentReady(after: max(0, Date().timeIntervalSince(startedAt)), fromCache: true)
                measuredContent = true
            }
        }
        guard request == generation, !Task.isCancelled else { return }
        // These two catalogue capabilities can answer from the persistent local index.
        // History and genre requests are skipped while offline.
        if !isOnline, !isEmpty { return }
        let starredService = libraryService as? any StarredBrowsing
        pendingSections = isOnline ? [.playlists, .history, .recent, .genres, .habits] : [.playlists, .recent]
        if isOnline && starredService != nil { pendingSections.insert(.favorites) }
        let service = libraryService
        var staged = snapshot
        await withTaskGroup(of: SectionResult.self) { group in
            group.addTask {
                await Self.fetch(.playlists) {
                    .playlists(try await service.playlists().sorted {
                        ($0.changed ?? $0.created ?? .distantPast) > ($1.changed ?? $1.created ?? .distantPast)
                    })
                }
            }
            group.addTask { await Self.fetch(.recent) { .recent(try await service.recentlyAddedAlbums(size: 60)) } }
            if isOnline {
                group.addTask { await Self.fetch(.habits) { .habits(try await service.mostPlayedAlbums(size: 40)) } }
                if let starredService {
                    group.addTask {
                        await Self.fetch(.favorites) {
                            let starred = try await starredService.getStarred2()
                            return .favorites(HomeFavorites(songs: Array((starred.song ?? []).prefix(60)),
                                albums: Array((starred.album ?? []).prefix(40)), artists: Array((starred.artist ?? []).prefix(100))))
                        }
                    }
                }
                group.addTask { await Self.fetch(.history) { .history(try await service.recentlyPlayedAlbums(size: 20)) } }
                group.addTask {
                    await Self.fetch(.genres) {
                        let genres = try await service.genres()
                            .filter { $0.albumCount > 0 }.sorted { $0.albumCount > $1.albumCount }.prefix(5)
                        var shelves: [GenreShelf] = []
                        // A separate task from the main shelves: a slow genre never holds them back.
                        for genre in genres {
                            try Task.checkCancellation()
                            let albums = try await service.albumsByGenre(genre.value, size: 20)
                            if !albums.isEmpty { shelves.append(GenreShelf(name: genre.value, albums: albums)) }
                        }
                        return .genres(shelves)
                    }
                }
            }
            for await result in group {
                guard request == generation, !Task.isCancelled else { group.cancelAll(); return }
                pendingSections.remove(result.section)
                switch result {
                case .playlists(let values): staged.playlists = values.prefix(60).map(IndexedPlaylistPayload.init)
                case .history(let values): staged.recentlyPlayed = values
                case .recent(let values): staged.recentlyAdded = values
                case .genres(let values): staged.genres = values
                case .favorites(let values): staged.favorites = values
                case .habits(let values): staged.mostPlayed = HomePersonalization.unique(values)
                case .failure(_, let failure):
                    hasPartialFailure = true
                    error = error ?? failure
                case .cancelled: break
                }
                // Cold loading displays shelves independently. Pull-to-refresh commits once, so its
                // changing content height cannot strand List/ScrollView's refresh inset.
                if !preserveLayout { apply(staged) }
                if !measuredContent, !isEmpty {
                    diagnostics?.recordHomeContentReady(after: max(0, Date().timeIntervalSince(startedAt)), fromCache: false)
                    measuredContent = true
                }
            }
        }
        guard request == generation, !Task.isCancelled else { return }
        if preserveLayout { apply(staged) }
        if !measuredContent, !isEmpty {
            diagnostics?.recordHomeContentReady(after: max(0, Date().timeIntervalSince(startedAt)), fromCache: false)
        }
        if let cache, let serverID { try? await cache.save(snapshot, serverID: serverID) }
    }

    private nonisolated static func fetch(_ section: Section, operation: @Sendable () async throws -> SectionResult) async -> SectionResult {
        do { return try await operation() }
        catch {
            return UserFacingError.isCancellation(error) ? .cancelled(section) : .failure(section, UserFacingError.from(error))
        }
    }

    private var snapshot: HomeFeedSnapshot {
        HomeFeedSnapshot(playlists: topPicks.map(IndexedPlaylistPayload.init), recentlyPlayed: recentlyPlayed, recentlyAdded: recentlyAdded, genres: genreShelves, favorites: favorites, mostPlayed: mostPlayed)
    }

    private func apply(_ snapshot: HomeFeedSnapshot) {
        topPicks = snapshot.playlists.map(\.summary)
        recentlyPlayed = snapshot.recentlyPlayed
        recentlyAdded = snapshot.recentlyAdded
        genreShelves = snapshot.genres
        favorites = snapshot.favorites ?? HomeFavorites()
        mostPlayed = snapshot.mostPlayed ?? []
    }
}
