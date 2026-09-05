import Foundation
import Observation

struct PlaylistAdditionRequest: Identifiable {
    let id = UUID()
    let songs: [DisplayableSong]
    var createsPlaylist = false
}

/// Owns the Add to Playlist selection for one SwiftUI presentation context.
@MainActor
@Observable
final class PlaylistAddition {
    var request: PlaylistAdditionRequest?

    var selectedSong: DisplayableSong? { request?.songs.first }

    func present(_ song: DisplayableSong) {
        present(songs: [song])
    }

    func present(songs: [DisplayableSong], createsPlaylist: Bool = false) {
        guard !songs.isEmpty else { return }
        request = PlaylistAdditionRequest(songs: songs, createsPlaylist: createsPlaylist)
    }

    func dismiss() {
        request = nil
    }
}
