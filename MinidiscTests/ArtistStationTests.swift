import Foundation
import SwiftSonic
import Testing
@testable import Minidisc

@Suite("Personal artist stations")
@MainActor
struct ArtistStationTests {
    @Test("Stations keep real artist IDs, prioritize favorites, and deduplicate listening history")
    func rankedSeeds() throws {
        let favorites = HomeFavorites(artists: [ArtistID3(id: "favorite", name: "Echo")])
        let recent = try album(id: "r", artistID: "recent", name: "Echo")
        let repeated = try album(id: "f", artistID: "favorite", name: "Echo")
        let unknown = try album(id: "u", artistID: nil, name: "Unknown")
        let result = ArtistStation.suggestions(favorites: favorites, recent: [recent, repeated, unknown], frequent: [recent])
        #expect(result.map(\.id) == ["favorite", "recent"])
        #expect(result.allSatisfy { $0.starter == nil })
    }

    @Test("A favorite song supplies the starter for its own artist only")
    func immediateStarter() throws {
        let song = try JSONDecoder().decode(Song.self, from: Data(#"{"id":"seed","title":"Aurore","artist":"Ensemble","artistId":"artist","isDir":false}"#.utf8))
        let favorites = HomeFavorites(songs: [song], artists: [ArtistID3(id: "other", name: "Ensemble")])
        let result = ArtistStation.suggestions(favorites: favorites, recent: [], frequent: [])
        #expect(result.map(\.id) == ["other", "artist"])
        #expect(result[0].starter == nil)
        #expect(result[1].starter?.id == "seed")
        #expect(ArtistStation.suggestions(favorites: favorites, recent: [], frequent: [], limit: 1).count == 1)
    }

    @Test("An unavailable history source does not hide favorite stations; a failed refresh preserves them")
    func partialFailure() async {
        let library = StationLibrary()
        let vm = DiscoverViewModel(libraryService: library, recommendationService: RecommendationService(providers: []))
        await vm.load()
        #expect(vm.stations.map(\.id) == ["favorite"])
        library.failFavorites = true
        await vm.load(forceRefresh: true)
        #expect(vm.stations.map(\.id) == ["favorite"])
        #expect(!vm.isLoading)
        #expect(vm.loadError != nil)
    }

    private func album(id: String, artistID: String?, name: String) throws -> AlbumID3 {
        var object: [String: Any] = ["id": id, "name": id, "artist": name, "songCount": 1, "duration": 30]
        object["artistId"] = artistID
        return try JSONDecoder().decode(AlbumID3.self, from: JSONSerialization.data(withJSONObject: object))
    }
}

@MainActor
private final class StationLibrary: ListeningHistoryBrowsing, StarredBrowsing {
    var failFavorites = false
    func recentlyPlayedAlbums(size: Int) async throws -> [AlbumID3] { throw URLError(.timedOut) }
    func mostPlayedAlbums(size: Int) async throws -> [AlbumID3] { throw URLError(.timedOut) }
    func getStarred2() async throws -> Starred2 {
        if await MainActor.run(body: { failFavorites }) { throw URLError(.timedOut) }
        return try JSONDecoder().decode(Starred2.self, from: Data(#"{"artist":[{"id":"favorite","name":"Ensemble"}]}"#.utf8))
    }
}
