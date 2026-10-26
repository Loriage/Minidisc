import Foundation
import CryptoKit
import SwiftSonic

/// Presentation metadata for the shared library. Playback always keeps the original
/// DisplayableSong and its file reference; these IDs must never reach a server API.
nonisolated struct LocalMusicCatalog {
    let albums: [AlbumID3]
    let artists: [ArtistID3]
    let songs: [DisplayableSong]
    let groups: [String: LocalMusicGroup]
    let availableSongIDs: Set<String>

    init(tracks: [LocalMusicTrack] = []) {
        let albumGroups = LocalMusicGroup.groups(in: tracks, category: .albums)
        let artistGroups = LocalMusicGroup.groups(in: tracks, category: .artists)
        groups = Dictionary(uniqueKeysWithValues:
            albumGroups.map { (Self.collectionID(.albums, key: $0.id), $0) }
            + artistGroups.map { (Self.collectionID(.artists, key: $0.id), $0) })
        songs = tracks.map(\.song)
        availableSongIDs = Set(tracks.filter(\.isAvailable).map(\.id))
        albums = albumGroups.map { group in
            AlbumID3(id: Self.collectionID(.albums, key: group.id), name: group.name,
                     songCount: group.tracks.count,
                     duration: Int(group.tracks.reduce(0) { $0 + $1.song.duration }),
                     artist: group.tracks.first?.song.artist,
                     coverArt: group.artworkID, created: group.addedAt)
        }
        artists = artistGroups.map { group in
            ArtistID3(id: Self.collectionID(.artists, key: group.id), name: group.name,
                      albumCount: LocalMusicGroup.groups(in: group.tracks, category: .albums).count,
                      coverArt: group.artworkID)
        }
    }

    static func collectionID(_ category: LocalMusicCategory, key: [String]) -> String {
        // Length-prefixed components avoid collisions between names containing separators.
        let value = key.map { "\($0.utf8.count):\($0)" }.joined()
        let digest = SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        return "local-\(category.rawValue):\(digest)"
    }

    static func isCollectionID(_ id: String) -> Bool {
        id.hasPrefix("local-albums:") || id.hasPrefix("local-artists:")
    }

    func playable(_ songs: [DisplayableSong]) -> [DisplayableSong] {
        songs.filter { !$0.isLocalFile || availableSongIDs.contains($0.id) }
    }
}

nonisolated enum LocalMusicCategory: String, CaseIterable, Identifiable {
    case albums, artists, songs
    var id: String { rawValue }
    var title: LocalizedStringResource {
        switch self {
        case .albums: "Albums"
        case .artists: "Artists"
        case .songs: "Songs"
        }
    }
}

nonisolated struct LocalMusicGroup: Identifiable {
    let id: [String]
    let name: String
    let tracks: [LocalMusicTrack]
    var artworkID: String { tracks.first?.song.coverArtId ?? tracks.first?.id ?? "local:" }

    static func key(for track: LocalMusicTrack, category: LocalMusicCategory) -> [String] {
        category == .albums
            ? [track.song.albumName ?? "", track.song.artist ?? ""]
            : [track.song.artist ?? ""]
    }

    static func groups(in tracks: [LocalMusicTrack], category: LocalMusicCategory) -> [Self] {
        Dictionary(grouping: tracks) { key(for: $0, category: category) }.map { key, tracks in
            Self(id: key, name: key[0].isEmpty
                 ? (category == .albums ? String(localized: "Unknown Album", table: "LocalMusic") : String(localized: "Unknown Artist", table: "LocalMusic"))
                 : key[0], tracks: tracks)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

extension LocalMusicTrack {
    /// Preserve the displayed order so turning Shuffle off can restore it.
    nonisolated static func playbackQueue(_ tracks: [Self], order: PreparedPlaybackQueue.Order = .ordered,
                                         startingAt selectedID: String? = nil) throws -> PreparedPlaybackQueue {
        if let selectedID, tracks.first(where: { $0.id == selectedID })?.isAvailable != true {
            throw LocalMusicError.unavailable
        }
        let songs = tracks.filter(\.isAvailable).map(\.song)
        guard !songs.isEmpty else { throw LocalMusicError.unavailable }
        let index = selectedID.flatMap { id in songs.firstIndex { $0.id == id } } ?? 0
        return PreparedPlaybackQueue(tracks: songs, startIndex: index, order: order)
    }
}

/// Stable collection identity for navigation from the player, independent of server state.
nonisolated struct LocalMusicDestination: Hashable, Sendable {
    let category: LocalMusicCategory
    let key: [String]

    init?(track: DisplayableSong?, category: LocalMusicCategory) {
        guard let track, track.isLocalFile, category != .songs else { return nil }
        self.category = category
        key = LocalMusicGroup.key(for: LocalMusicTrack(song: track, isAvailable: true), category: category)
    }
}

extension LocalMusicTrack {
    nonisolated var recency: Date { addedAt ?? modified ?? .distantPast }

    nonisolated static func mostRecentFirst(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.recency != rhs.recency { return lhs.recency > rhs.recency }
        let order = lhs.song.title.localizedStandardCompare(rhs.song.title)
        return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
    }
}

extension LocalMusicGroup {
    nonisolated var addedAt: Date { tracks.map(\.recency).max() ?? .distantPast }
    nonisolated var scrollID: String { id.description }
}
