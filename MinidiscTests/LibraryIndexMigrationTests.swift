import Foundation
import SwiftData
import SwiftSonic
import Testing
@testable import Minidisc

private final class LibraryIndexFixtureBundle: NSObject {}

@Suite("Library index upgrades", .serialized) @MainActor
struct LibraryIndexMigrationTests {
    private let serverID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let syncedAt = Date(timeIntervalSince1970: 1_700_000_000)

    @Test(arguments: [1, 2, 3, 4])
    func installedStoreOpensWithoutLosingItsCache(version: Int) throws {
        let fixture = try #require(Bundle(for: LibraryIndexFixtureBundle.self)
            .url(forResource: "index-v\(version)", withExtension: "sqlite"))
        let directory = URL.temporaryDirectory.appendingPathComponent("index-upgrade-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        try FileManager.default.copyItem(at: fixture, to: url)

        // Reopen the migrated database too: a successful first migration must not strand the next launch.
        for _ in 0..<2 {
            let container = try ModelContainer.libraryIndex(storeURL: url)
            let context = ModelContext(container)
            let tracks = try context.fetch(FetchDescriptor<IndexedTrack>())
            #expect(tracks.count == 1)
            let track = try #require(tracks.first)
            #expect(track.serverId == serverID)
            #expect(track.itemId == "track")
            #expect(track.serverOrder == 7)
            #expect(track.createdAt == syncedAt)
            #expect(track.generation == "original")
            #expect(try JSONDecoder().decode(Song.self, from: track.payload).title == "Preserved Track")
            let albums = try context.fetch(FetchDescriptor<IndexedAlbum>())
            #expect(albums.map(\.itemId) == ["album"])
            #expect(albums.first?.name == "Preserved Album")
            #expect(try context.fetch(FetchDescriptor<IndexedArtist>()).map(\.name) == ["Preserved Artist"])
            let state = try #require(context.fetch(FetchDescriptor<LibraryIndexState>()).first)
            #expect(state.serverId == serverID)
            #expect(state.artistsSyncedAt == syncedAt)
            #expect(state.albumsSyncedAt == syncedAt)
            #expect(state.tracksSyncedAt == syncedAt)

            let playlists = try context.fetch(FetchDescriptor<IndexedPlaylist>())
            #expect(playlists.count == (version >= 2 ? 1 : 0))
            let playlistStates = try context.fetch(FetchDescriptor<PlaylistIndexState>())
            #expect(playlistStates.count == (version >= 2 ? 1 : 0))
            if version >= 2 {
                let playlist = try #require(playlists.first)
                #expect(playlist.serverId == serverID)
                #expect(playlist.serverOrder == 3)
                #expect(playlist.detailSummaryPayload == playlist.summaryPayload)
                let payload = try #require(playlist.detailPayload)
                let detail = try JSONDecoder().decode(IndexedPlaylistPayload.self, from: payload)
                #expect(detail.name == "Preserved Playlist")
                #expect(detail.entry?.map(\.id) == ["track", "track"])
                #expect(playlistStates.first?.syncedAt == syncedAt)
            }
            let recommendations = try context.fetch(FetchDescriptor<IndexedAlbumRecommendation>())
            #expect(recommendations.count == (version >= 3 ? 1 : 0))
            if version >= 3 {
                let recommendation = try #require(recommendations.first)
                #expect(recommendation.serverId == serverID)
                #expect(recommendation.refreshedAt == syncedAt)
                #expect(recommendation.requestedLimit == 20)
                #expect(try JSONDecoder().decode([AlbumID3].self, from: recommendation.payload).map(\.id) == ["album"])
            }
            let legacyMarkers = try context.fetch(FetchDescriptor<LibraryIndexSchemaV4.TrackSearchIndexState>())
            #expect(legacyMarkers.count == (version == 4 ? 1 : 0))
            if version == 4 {
                #expect(legacyMarkers.first?.serverId == serverID)
                #expect(legacyMarkers.first?.version == 1)
            }
        }
    }

    @Test func freshStoreRemainsReadableOnTheNextLaunch() throws {
        let directory = URL.temporaryDirectory.appendingPathComponent("index-fresh-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        do {
            let container = try ModelContainer.libraryIndex(storeURL: url)
            let context = ModelContext(container)
            let state = LibraryIndexState(serverId: serverID)
            state.tracksSyncedAt = syncedAt
            context.insert(state)
            try context.save()
        }
        let reopened = try ModelContainer.libraryIndex(storeURL: url)
        let state = try #require(ModelContext(reopened).fetch(FetchDescriptor<LibraryIndexState>()).first)
        #expect(state.serverId == serverID)
        #expect(state.tracksSyncedAt == syncedAt)
    }

    @Test(arguments: [false, true])
    func removingOrResettingAServerAlsoPurgesItsLegacyMarker(reset: Bool) async throws {
        let container = try ModelContainer.libraryIndex(inMemory: true)
        let context = ModelContext(container)
        let otherServerID = UUID()
        context.insert(LibraryIndexSchemaV4.TrackSearchIndexState(serverId: serverID, version: 1))
        context.insert(LibraryIndexSchemaV4.TrackSearchIndexState(serverId: otherServerID, version: 1))
        try context.save()
        let store = LibraryIndexStore(modelContainer: container)
        if reset { try await store.resetServer(serverID) }
        else { try await store.removeServer(serverID) }
        let remaining = try ModelContext(container).fetch(FetchDescriptor<LibraryIndexSchemaV4.TrackSearchIndexState>())
        #expect(remaining.map(\.serverId) == [otherServerID])
        try await store.eraseAll()
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<LibraryIndexSchemaV4.TrackSearchIndexState>()) == 0)
    }
}
