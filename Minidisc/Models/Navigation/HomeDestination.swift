import SwiftSonic

nonisolated enum HomeDestination: Hashable {

    case libraryAlbums
    case libraryArtists
    case librarySongs
    case libraryPlaylists
    case libraryFavorites
    case libraryDownloads

    case album(AlbumID3)
    case artist(ArtistID3)
    case playlist(Playlist)
    case downloadedAlbum(DownloadedAlbumDisplay)

    case albumById(id: String, name: String, subtitle: String, coverArtId: String?)
    case playlistById(id: String, name: String, coverArtId: String?)
    case artistById(id: String, name: String, coverArtId: String?)

    /// "The best of <artist>" — the user's starred tracks for one artist, computed from getStarred2.
    /// Carries only identity: the track list is never persisted, it is recomputed by the screen.
    case artistBestOf(artistId: String, artistName: String, coverArtId: String?)
    /// "Recently Added" — the tracks of the library's newest albums, computed from getAlbumList2(newest).
    /// Carries only the cover of the newest album, so the hero has artwork while the tracks load; the list
    /// itself is never persisted, the screen recomputes it.
    case recentlyAdded(coverArtId: String?)

    case offlineArtist(OfflineArtistSummary)
    case offlineAlbum(OfflineAlbumSummary)
}
