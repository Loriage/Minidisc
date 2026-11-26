import Foundation
import SwiftSonic
import Testing
@testable import Minidisc

@Suite("Home personalization")
@MainActor
struct HomePersonalizationTests {
    @Test("Rediscovery removes duplicates and the latest listening history")
    func rediscovery() throws {
        let a = try album("a", artistID: "artist")
        let b = try album("b", artistID: "artist")
        let c = try album("c", artistID: "artist")
        #expect(HomePersonalization.rediscovery(favorites: [a, b], frequent: [b, c], recent: [a]).map(\.id) == ["b", "c"])
    }

    @Test("Relevant additions use favorite artists and listening habits without inventing matches")
    func relevantArtists() throws {
        let favorite = try album("favorite", artistID: "favorite-artist")
        let familiar = try album("familiar", artistID: "frequent-artist")
        let newFavorite = try album("new-favorite", artistID: "favorite-artist")
        let newFamiliar = try album("new-familiar", artistID: "frequent-artist")
        let stranger = try album("stranger", artistID: "another-artist")
        let result = HomePersonalization.relevantAdditions([newFavorite, stranger, newFamiliar, newFavorite],
            favorites: HomeFavorites(albums: [favorite]), frequent: [familiar])
        #expect(result.map(\.id) == ["new-favorite", "new-familiar"])
    }

    @Test("Artist names are a fallback only when IDs are absent")
    func missingArtistIDs() throws {
        let favorites = HomeFavorites(artists: [ArtistID3(id: "known", name: "Beyoncé")])
        let sameNameOtherID = try album("other", artistID: "other-artist", artist: "Beyonce")
        let missingID = try album("missing", artistID: nil, artist: "Beyonce")
        #expect(HomePersonalization.relevantAdditions([sameNameOtherID, missingID], favorites: favorites, frequent: []).map(\.id) == ["missing"])
    }

    @Test("The earlier offline Home cache still decodes after the new shelves")
    func oldCacheRemainsReadable() throws {
        let data = Data(#"{"playlists":[],"recentlyPlayed":[],"recentlyAdded":[],"genres":[]}"#.utf8)
        let snapshot = try JSONDecoder().decode(HomeFeedSnapshot.self, from: data)
        #expect(snapshot.favorites == nil)
        #expect(snapshot.mostPlayed == nil)
    }

    @Test("Personal shelves survive serialization for an offline relaunch")
    func cacheRoundTrip() throws {
        let favorite = try album("favorite", artistID: "a")
        let source = HomeFeedSnapshot(favorites: HomeFavorites(albums: [favorite]), mostPlayed: [favorite])
        let restored = try JSONDecoder().decode(HomeFeedSnapshot.self, from: JSONEncoder().encode(source))
        #expect(restored.favorites?.albums.map(\.id) == ["favorite"])
        #expect(restored.mostPlayed?.map(\.id) == ["favorite"])
    }

    private func album(_ id: String, artistID: String?, artist: String = "Artist") throws -> AlbumID3 {
        var object: [String: Any] = ["id": id, "name": id, "artist": artist, "songCount": 1, "duration": 180]
        object["artistId"] = artistID
        return try JSONDecoder().decode(AlbumID3.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
