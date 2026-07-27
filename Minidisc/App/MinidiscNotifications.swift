// Minidisc — Music client for Subsonic/OpenSubsonic servers
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

// MARK: - Player navigation helpers

func postNavigateToAlbum(track: DisplayableSong) {
    guard let albumId = track.albumId else { return }
    NotificationCenter.default.post(
        name: .minidiscNavigateToAlbum,
        object: nil,
        userInfo: [
            "albumId":   albumId,
            "albumName": track.albumName ?? "",
            "coverArtId": track.coverArtId as Any
        ]
    )
}

func postNavigateToArtist(track: DisplayableSong) {
    guard let artistId = track.artistId else { return }
    postNavigateToArtist(artistId: artistId, artistName: track.artist ?? "", coverArtId: track.coverArtId)
}

func postNavigateToArtist(artistId: String, artistName: String, coverArtId: String?) {
    NotificationCenter.default.post(
        name: .minidiscNavigateToArtist,
        object: nil,
        userInfo: [
            "artistId":   artistId,
            "artistName": artistName,
            "coverArtId": coverArtId as Any
        ]
    )
}

func postNavigateToPlaylist(playlistId: String, name: String, coverArtId: String?) {
    NotificationCenter.default.post(
        name: .minidiscNavigateToPlaylist,
        object: nil,
        userInfo: [
            "playlistId": playlistId,
            "name":       name,
            "coverArtId": coverArtId as Any
        ]
    )
}

/// A playlist was deleted (server-confirmed) from a detail surface. The playlist list observes this to reload,
/// so the deleted playlist disappears on return without a manual refresh — and without an `.onAppear` reload.
func postPlaylistDeleted() {
    NotificationCenter.default.post(name: .minidiscPlaylistDeleted, object: nil)
}

extension Notification.Name {
    static let minidiscNavigateToAlbum    = Notification.Name("minidiscNavigateToAlbum")
    static let minidiscNavigateToArtist   = Notification.Name("minidiscNavigateToArtist")
    static let minidiscNavigateToPlaylist = Notification.Name("minidiscNavigateToPlaylist")
    static let minidiscPlaylistDeleted    = Notification.Name("minidisc.playlistDeleted")
    /// The Lidarr library changed (an artist was added or removed) — the Lidarr tab reloads.
    static let lidarrLibraryDidChange     = Notification.Name("minidisc.lidarrLibraryDidChange")
    /// The Lidarr queue changed (an item was imported or removed) — the queue view reloads.
    static let lidarrQueueDidChange       = Notification.Name("minidisc.lidarrQueueDidChange")
}
