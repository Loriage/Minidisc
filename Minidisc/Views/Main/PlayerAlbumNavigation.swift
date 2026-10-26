import SwiftUI

/// A snapshot of the album selected at the time of the command, scoped to its server.
nonisolated struct PlayerAlbumDestination: Hashable, Sendable {
    let serverID: UUID
    let albumID: String
    let name: String
    let coverArtID: String?

    init?(track: DisplayableSong?, serverID: UUID?, isLiveStream: Bool,
          isOnline: Bool, offlineAlbumIDs: Set<String>) {
        guard !isLiveStream, let track, !track.isLocalFile,
              let serverID, let albumID = track.albumId, !albumID.isEmpty,
              isOnline || offlineAlbumIDs.contains(albumID) else { return nil }
        self.serverID = serverID
        self.albumID = albumID
        name = track.albumName ?? ""
        coverArtID = track.coverArtId
    }
}

/// Presentation bookkeeping only; the existing navigation paths still own the back stacks.
@MainActor
final class PlayerAlbumNavigation {
    enum Tab: String, Hashable, CaseIterable { case home, discover, library, lidarr, search }
    enum Action: Equatable { case reveal(Tab), push(Tab) }

    private struct VisibleAlbum {
        let albumID: String
        let serverID: UUID
        let owner: UUID
    }
    private var visibleAlbums: [Tab: VisibleAlbum] = [:]

    func appeared(albumID: String, serverID: UUID, in tab: Tab, owner: UUID) {
        visibleAlbums[tab] = VisibleAlbum(albumID: albumID, serverID: serverID, owner: owner)
    }

    func disappeared(in tab: Tab, owner: UUID) {
        // A retiring page must not clear a newer page's registration during a transition.
        guard visibleAlbums[tab]?.owner == owner else { return }
        visibleAlbums[tab] = nil
    }

    func action(for album: PlayerAlbumDestination, from tab: Tab, activeServerID: UUID?) -> Action? {
        guard album.serverID == activeServerID else { return nil }
        let target: Tab = tab == .lidarr ? .home : tab
        if let visible = visibleAlbums[target],
           visible.serverID == album.serverID, visible.albumID == album.albumID {
            return .reveal(target)
        }
        return .push(target)
    }

    func reset() { visibleAlbums.removeAll() }
}

struct AlbumNavigationContext: Equatable {
    let navigation: PlayerAlbumNavigation
    let tab: PlayerAlbumNavigation.Tab

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.navigation === rhs.navigation && lhs.tab == rhs.tab
    }
}

extension EnvironmentValues {
    @Entry var albumNavigationContext: AlbumNavigationContext? = nil
}

extension View {
    func playerAlbumDestinations() -> some View {
        navigationDestination(for: PlayerAlbumDestination.self) { album in
            AlbumDetailView(albumId: album.albumID, albumName: album.name, coverArtId: album.coverArtID)
        }
        .navigationDestination(for: LocalMusicDestination.self) { destination in
            LocalMusicDestinationView(destination: destination)
        }
    }
}

private struct LocalMusicDestinationView: View {
    let destination: LocalMusicDestination
    @Environment(\.appContainer) private var container

    var body: some View {
        if let group = LocalMusicGroup.groups(in: container?.localMusic.snapshot.tracks ?? [], category: destination.category)
            .first(where: { $0.id == destination.key }) {
            LocalMusicCollectionView(group: group, category: destination.category)
        } else {
            ContentUnavailableView {
                Label { Text("Local Files", tableName: "LocalMusic") } icon: { Image(systemName: "folder") }
            } description: {
                Text("No audio files found. Check your folders in Files, then refresh.", tableName: "LocalMusic")
            }
        }
    }
}
