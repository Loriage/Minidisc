import Observation

/// Owns the Add to Playlist selection for one SwiftUI presentation context.
@MainActor
@Observable
final class PlaylistAddition {
    var selectedSong: DisplayableSong?

    func present(_ song: DisplayableSong) {
        selectedSong = song
    }

    func dismiss() {
        selectedSong = nil
    }
}
