import Foundation
import SwiftData
import SwiftSonic
import Testing
@testable import Minidisc

private actor FailingFavoriteEditor: FavoriteEditing {
    var shouldFail = true
    func setFailure(_ value: Bool) { shouldFail = value }
    func star(songIds: [String], albumIds: [String], artistIds: [String]) async throws {
        if shouldFail { throw URLError(.timedOut) }
    }
    func unstar(songIds: [String], albumIds: [String], artistIds: [String]) async throws {
        if shouldFail { throw URLError(.timedOut) }
    }
    func getStarred2() async throws -> Starred2 { throw URLError(.timedOut) }
}

@Suite @MainActor
struct FavoritesFailureTests {
    @Test func failedFavoriteActionsRestoreThePersistedState() async throws {
        let container = try ModelContainer.minidisc(inMemory: true)
        let state = ServerState()
        state.activeServer = ServerSnapshot(from: ServerConfig(displayName: "Test", baseURL: "https://example.invalid", username: "test"))
        let editor = FailingFavoriteEditor()
        let service = FavoritesService(libraryService: editor, serverState: state, modelContainer: container)
        do { try await service.star(itemType: .song, itemId: "track"); Issue.record("Expected server failure") }
        catch { }
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<FavoriteRecord>()) == 0)
        await editor.setFailure(false)
        try await service.star(itemType: .song, itemId: "track")
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<FavoriteRecord>()) == 1)
        await editor.setFailure(true)
        do { try await service.unstar(itemType: .song, itemId: "track"); Issue.record("Expected server failure") }
        catch { }
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<FavoriteRecord>()) == 1)
    }

    @Test func missingServerCannotReportFavoriteSuccess() async throws {
        let container = try ModelContainer.minidisc(inMemory: true)
        let service = FavoritesService(libraryService: FailingFavoriteEditor(), serverState: ServerState(), modelContainer: container)
        do { try await service.star(itemType: .song, itemId: "track"); Issue.record("Expected missing server") }
        catch MinidiscError.serverNotConfigured { }
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<FavoriteRecord>()) == 0)
    }
}

@Suite @MainActor
struct FavoriteServerIsolationTests {
    @Test func identicalSongIDsHaveIndependentFavorites() async throws {
        let container = try ModelContainer.minidisc(inMemory: true)
        let state = ServerState()
        let first = ServerSnapshot(from: ServerConfig(displayName: "A", baseURL: "https://a.invalid", username: "u"))
        let second = ServerSnapshot(from: ServerConfig(displayName: "B", baseURL: "https://b.invalid", username: "u"))
        let editor = FailingFavoriteEditor()
        await editor.setFailure(false)
        let service = FavoritesService(libraryService: editor, serverState: state, modelContainer: container)
        state.activeServer = first
        try await service.star(itemType: .song, itemId: "same")
        state.activeServer = second
        #expect(!service.isFavorite(itemType: .song, itemId: "same"))
        try await service.star(itemType: .song, itemId: "same")
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<FavoriteRecord>()) == 2)
        try await service.unstar(itemType: .song, itemId: "same")
        #expect(!service.isFavorite(itemType: .song, itemId: "same"))
        state.activeServer = first
        #expect(service.isFavorite(itemType: .song, itemId: "same"))
    }

    @Test func pinsAndTheirLimitAreScopedToTheActiveServer() throws {
        let container = try ModelContainer.minidisc(inMemory: true)
        let state = ServerState()
        let a = ServerSnapshot(from: ServerConfig(displayName: "A", baseURL: "https://a.invalid", username: "u"))
        let b = ServerSnapshot(from: ServerConfig(displayName: "B", baseURL: "https://b.invalid", username: "u"))
        let service = PinService(modelContainer: container, serverState: state)
        state.activeServer = a
        for index in 0..<6 {
            try service.pin(itemType: .album, itemId: "\(index)", displayName: "Album", displaySubtitle: "Artist", coverArtId: nil, serverId: a.id)
        }
        state.activeServer = b
        #expect(service.currentPinnedCount() == 0)
        #expect(!service.isPinned(itemType: .album, itemId: "0"))
        try service.pin(itemType: .album, itemId: "0", displayName: "Other", displaySubtitle: "Artist", coverArtId: nil, serverId: b.id)
        service.unpin(itemType: .album, itemId: "0")
        state.activeServer = a
        #expect(service.currentPinnedCount() == 6)
        #expect(service.isPinned(itemType: .album, itemId: "0"))
    }

    @Test func legacyKeysMigrateIdempotentlyWithoutLosingMetadata() throws {
        let container = try ModelContainer.minidisc(inMemory: true)
        let serverID = UUID()
        let date = Date(timeIntervalSince1970: 123456)
        let context = ModelContext(container)
        let favorite = FavoriteRecord(itemType: .song, itemId: "same", starredDate: date, serverId: serverID)
        favorite.id = "song:same"
        let pin = PinnedItem(itemType: .album, itemId: "same", displayName: "Original", displaySubtitle: "Artist", coverArtId: "cover", serverId: serverID, sortOrder: 3)
        pin.id = "album:same"
        context.insert(favorite)
        context.insert(pin)
        try context.save()
        try ServerItemIdentity.migrate(in: container)
        try ServerItemIdentity.migrate(in: container)
        let read = ModelContext(container)
        let favorites = try read.fetch(FetchDescriptor<FavoriteRecord>())
        let pins = try read.fetch(FetchDescriptor<PinnedItem>())
        #expect(favorites.count == 1 && pins.count == 1)
        #expect(favorites.first?.id == ServerItemIdentity.key(serverID: serverID, type: "song", itemID: "same"))
        #expect(favorites.first?.starredDate == date)
        #expect(pins.first?.id == ServerItemIdentity.key(serverID: serverID, type: "album", itemID: "same"))
        #expect(pins.first?.displayName == "Original")
        #expect(pins.first?.sortOrder == 3)
        #expect(pins.first?.coverArtId == "cover")
    }
}
