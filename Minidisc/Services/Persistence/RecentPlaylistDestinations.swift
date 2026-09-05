import Foundation

/// Stores only successful destinations, separately for each server. Missing playlists disappear
/// when the caller resolves these IDs against the current catalogue.
@MainActor
final class RecentPlaylistDestinations {
    private let defaults: UserDefaults
    private let key: String

    init(serverID: String, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        key = "minidisc.recentPlaylistDestinations.\(serverID)"
    }

    var ids: [String] { defaults.stringArray(forKey: key) ?? [] }

    func record(_ id: String) {
        defaults.set(Array(([id] + ids.filter { $0 != id }).prefix(5)), forKey: key)
    }
}
