import Foundation

/// Decides which artists an album track list credits under each title.
nonisolated enum TrackArtistCredits {
    /// The credits to show under a track, or an empty array when the album artist alone performs it.
    /// When any other artist is credited, the full list is returned (album artist included) so the line
    /// reads like the release credits.
    static func credits(
        for song: DisplayableSong,
        albumArtistID: String?,
        albumArtistName: String?
    ) -> [ArtistCredit] {
        let credits = allCredits(for: song)
        guard !credits.isEmpty else { return [] }
        let hasGuest = credits.contains { !isAlbumArtist($0, id: albumArtistID, name: albumArtistName) }
        return hasGuest ? credits : []
    }

    /// Every artist credited on the track: OpenSubsonic `artists` when present, else the legacy artist field.
    static func allCredits(for song: DisplayableSong) -> [ArtistCredit] {
        if let artists = song.artists, !artists.isEmpty { return artists }
        guard let name = song.artist?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return []
        }
        return [ArtistCredit(id: song.artistId, name: name)]
    }

    private static func isAlbumArtist(_ credit: ArtistCredit, id: String?, name: String?) -> Bool {
        if let creditID = credit.id, let id, !id.isEmpty {
            return creditID == id
        }
        guard let name else { return false }
        return credit.name.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(name.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }
}
