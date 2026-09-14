import Foundation
import Intents
import SwiftSonic
import Testing
@testable import Minidisc

@Suite("Siri media requests")
@MainActor
struct SiriMediaIntentTests {
    private let scope = MusicIntentID.scope(baseURL: "https://music.example", username: "alice")

    @Test func selectsAlbumRatherThanNamesakeSongOrPlaylist() {
        let album = MusicIntentRecord(scope: scope, album: AlbumID3(id: "album", name: "Discovery", songCount: 14, duration: 3600, artist: "Daft Punk", created: Date()))
        let song = MusicIntentRecord(scope: scope, song: Song(id: "song", title: "Discovery"))
        let other = MusicIntentRecord(scope: scope, album: AlbumID3(id: "other", name: "Discovery Live", songCount: 1, duration: 180, artist: "Daft Punk", created: Date()))
        let search = mediaSearch(type: .album, title: "Discovery", artist: "Daft Punk")
        #expect(SiriMediaIntentHandler.filter([song, other, album], search: search, term: "Discovery").map(\.id) == [album.id])
    }

    @Test func artistDisambiguatesSameSongTitle() {
        let first = MusicIntentRecord(scope: scope, song: Song(id: "one", title: "One", artist: "U2"))
        let second = MusicIntentRecord(scope: scope, song: Song(id: "two", title: "One", artist: "Metallica"))
        #expect(SiriMediaIntentHandler.filter([first, second], search: mediaSearch(type: .song, title: "One", artist: "Metallica"), term: "One").map(\.id) == [second.id])
    }

    @Test func absentPlaylistDoesNotFallBackToAlbum() {
        let album = MusicIntentRecord(scope: scope, album: AlbumID3(id: "album", name: "Discovery", songCount: 14, duration: 3600, created: Date()))
        #expect(SiriMediaIntentHandler.filter([album], search: mediaSearch(type: .playlist, title: "Discovery"), term: "Discovery").isEmpty)
    }

    @Test func genericPlaybackDoesNotOverrideExplicitSearch() {
        #expect(SiriMediaIntentHandler.isResumeOrGeneric(intent()))
        #expect(!SiriMediaIntentHandler.isResumeOrGeneric(intent(search: mediaSearch(type: .album, title: "Discovery"))))
        #expect(!SiriMediaIntentHandler.isResumeOrGeneric(intent(search: mediaSearch(type: .playlist, title: nil))))
        #expect(SiriMediaIntentHandler.term(for: intent(search: mediaSearch(type: .song, title: "One", artist: "U2"))) == "One")
    }

    @Test func mediaItemsKeepStableAccountScopedIDs() {
        let record = MusicIntentRecord(scope: scope, song: Song(id: "song", title: "One", artist: "U2"))
        let item = SiriMediaIntentHandler.mediaItem(record)
        #expect(item.identifier == record.id)
        #expect(item.type == .song)
        #expect(item.artist == "U2")
        #expect(SiriMediaIntentHandler.repeatMode(.unknown) == nil)
        #expect(SiriMediaIntentHandler.repeatMode(.none) == .off)
        #expect(SiriMediaIntentHandler.repeatMode(.all) == .all)
    }

    @Test func unrecognizedPlaylistIdentifierStillAllowsNameLookup() {
        let item = INMediaItem(identifier: "external-service-playlist", title: "Discover Weekly", type: .playlist, artwork: nil)
        let request = intent(items: [item], search: mediaSearch(type: .playlist, title: "Discover Weekly"))
        #expect(SiriMediaIntentHandler.identifiers(for: request).isEmpty)
        #expect(SiriMediaIntentHandler.term(for: request) == "Discover Weekly")
        #expect(!SiriMediaIntentHandler.isResumeOrGeneric(request))
        let saved = MusicIntentRecord(scope: scope, playlist: Playlist(id: "weekly", name: "Discover Weekly", songCount: 30, duration: 6000))
        #expect(SiriMediaIntentHandler.identifiers(for: intent(items: [SiriMediaIntentHandler.mediaItem(saved)])) == [saved.id])
    }

    @Test func playlistOwnerIsNotTreatedAsAnArtist() {
        let record = MusicIntentRecord(scope: scope, playlist: Playlist(id: "weekly", name: "Discover Weekly", songCount: 30, duration: 6000, owner: "admin"))
        let result = SiriMediaIntentHandler.filter([record], search: mediaSearch(type: .playlist, title: "Discover Weekly", artist: "Daft Punk"), term: "Discover Weekly")
        #expect(result.map(\.id) == [record.id])
    }

    @Test func resolutionAndHandlingUseSharedContainer() async throws {
        let container = try AppContainer(inMemory: true, userDefaults: UserDefaults(suiteName: "SiriMediaTests.\(UUID())")!)
        let server = ServerSnapshot(from: ServerConfig(displayName: "Test", baseURL: "https://music.example", username: "alice"))
        container.serverState.activeServer = server
        container.serverState.isOnline = false
        try await container.libraryIndexStore.upsertTracks([Song(id: "one", title: "One")], serverID: server.id, generation: "test", serverOrderStart: 0)
        var loads = 0
        let handler = SiriMediaIntentHandler(runtime: MinidiscRuntime { loads += 1; return container })
        let record = MusicIntentRecord(scope: scope, song: Song(id: "one", title: "One"))
        let request = intent(items: [SiriMediaIntentHandler.mediaItem(record)])
        let first = await handler.resolveMediaItems(for: request)
        let second = await handler.resolveMediaItems(for: request)
        #expect(first.count == 1 && second.count == 1)
        #expect(loads == 1)
        let playlist = Playlist(id: "weekly", name: "Discover Weekly", songCount: 30, duration: 6000, owner: "admin")
        try await container.libraryIndexStore.cachePlaylistSummary(playlist, serverID: server.id)
        let playlistRecord = MusicIntentRecord(scope: scope, playlist: playlist)
        let search = INSearchForMediaIntent(mediaItems: [SiriMediaIntentHandler.mediaItem(playlistRecord)], mediaSearch: nil)
        let response = await handler.handle(intent: search)
        #expect(response.code == .success)
        #expect(response.mediaItems?.map(\.identifier) == [playlistRecord.id])
        #expect(container.playerState.currentTrack == nil)
        // A changed account must fail before touching playback.
        container.serverState.activeServer = ServerSnapshot(from: ServerConfig(displayName: "Other", baseURL: "https://other.example", username: "alice"))
        #expect(await handler.handle(intent: request).code == .failureRequiringAppLaunch)
        #expect(container.playerState.currentTrack == nil)
        #expect(await handler.handle(intent: search).code == .failureRequiringAppLaunch)
    }

    private func mediaSearch(type: INMediaItemType, title: String?, artist: String? = nil) -> INMediaSearch {
        INMediaSearch(mediaType: type, sortOrder: .unknown, mediaName: title, artistName: artist,
                      albumName: nil, genreNames: nil, moodNames: nil, releaseDate: nil, reference: .unknown, mediaIdentifier: nil)
    }

    private func intent(items: [INMediaItem]? = nil, search: INMediaSearch? = nil) -> INPlayMediaIntent {
        INPlayMediaIntent(mediaItems: items, mediaContainer: nil, playShuffled: nil, playbackRepeatMode: .unknown,
                          resumePlayback: nil, playbackQueueLocation: .now, playbackSpeed: nil, mediaSearch: search)
    }
}
