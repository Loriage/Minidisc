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
