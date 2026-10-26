import Foundation
import SwiftSonic
import Testing
@testable import Minidisc

@Suite("Album navigation from the player") @MainActor
struct PlayerAlbumNavigationTests {
    private let serverID = UUID()

    private func track(albumID: String? = "album") -> DisplayableSong {
        DisplayableSong(from: Song(id: "song", title: "Song", album: "Album", albumId: albumID))
    }

    private func destination(_ track: DisplayableSong? = nil) throws -> PlayerAlbumDestination {
        try #require(PlayerAlbumDestination(track: track ?? self.track(), serverID: serverID,
                                           isLiveStream: false, isOnline: true, offlineAlbumIDs: []))
    }

    @Test(arguments: PlayerAlbumNavigation.Tab.allCases)
    func retainsTheCurrentTabWithHomeFallbackForLidarr(tab: PlayerAlbumNavigation.Tab) throws {
        let navigation = PlayerAlbumNavigation()
        #expect(navigation.action(for: try destination(), from: tab, activeServerID: serverID)
                == .push(tab == .lidarr ? .home : tab))
    }

    @Test func revealsOnlyTheAlbumVisibleInTheTargetTabAndServer() throws {
        let navigation = PlayerAlbumNavigation()
        let album = try destination()
        let owner = UUID()
        navigation.appeared(albumID: album.albumID, serverID: serverID, in: .library, owner: owner)
        #expect(navigation.action(for: album, from: .library, activeServerID: serverID) == .reveal(.library))
        #expect(navigation.action(for: album, from: .search, activeServerID: serverID) == .push(.search))
        #expect(navigation.action(for: try destination(track(albumID: "other")), from: .library,
                                  activeServerID: serverID) == .push(.library))
        navigation.disappeared(in: .library, owner: owner)
        #expect(navigation.action(for: album, from: .library, activeServerID: serverID) == .push(.library))
        navigation.appeared(albumID: album.albumID, serverID: UUID(), in: .library, owner: UUID())
        #expect(navigation.action(for: album, from: .library, activeServerID: serverID) == .push(.library))
    }

    @Test func retiringPageCannotClearTheNewPageDuringNavigation() throws {
        let navigation = PlayerAlbumNavigation()
        let previous = UUID()
        navigation.appeared(albumID: "previous", serverID: serverID, in: .home, owner: previous)
        navigation.appeared(albumID: "album", serverID: serverID, in: .home, owner: UUID())
        navigation.disappeared(in: .home, owner: previous)
        #expect(navigation.action(for: try destination(), from: .home, activeServerID: serverID) == .reveal(.home))
        navigation.reset()
        #expect(navigation.action(for: try destination(), from: .home, activeServerID: serverID) == .push(.home))
    }

    @Test func capturesTheSelectedAlbumAndRejectsAServerSwitch() throws {
        var current = track()
        let request = try destination(current)
        current = track(albumID: "next-album")
        #expect(request.albumID == "album")
        #expect(try destination(current).albumID == "next-album")
        let navigation = PlayerAlbumNavigation()
        #expect(navigation.action(for: request, from: .home, activeServerID: UUID()) == nil)
        #expect(navigation.action(for: request, from: .home, activeServerID: nil) == nil)
    }

    @Test func offlineNavigationRequiresAnAlbumInTheLocalSnapshot() {
        #expect(PlayerAlbumDestination(track: track(), serverID: serverID, isLiveStream: false,
                                       isOnline: false, offlineAlbumIDs: ["album"]) != nil)
        #expect(PlayerAlbumDestination(track: track(), serverID: serverID, isLiveStream: false,
                                       isOnline: false, offlineAlbumIDs: ["other"]) == nil)
    }

    @Test func unavailableDestinationsStayDisabled() {
        for song in [nil, track(albumID: nil), track(albumID: "")] {
            #expect(PlayerAlbumDestination(track: song, serverID: serverID, isLiveStream: false,
                                           isOnline: true, offlineAlbumIDs: []) == nil)
        }
        #expect(PlayerAlbumDestination(track: track(), serverID: nil, isLiveStream: false,
                                       isOnline: true, offlineAlbumIDs: []) == nil)
        #expect(PlayerAlbumDestination(track: track(), serverID: serverID, isLiveStream: true,
                                       isOnline: true, offlineAlbumIDs: []) == nil)
        var local = track()
        local.localFile = LocalFileReference(folderID: UUID(), relativePath: "track.mp3")
        #expect(PlayerAlbumDestination(track: local, serverID: serverID, isLiveStream: false,
                                       isOnline: true, offlineAlbumIDs: []) == nil)
    }
}
