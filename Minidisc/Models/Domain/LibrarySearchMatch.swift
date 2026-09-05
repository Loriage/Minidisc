import Foundation
import SwiftSonic

enum LibrarySearchScope: String, CaseIterable, Identifiable, Hashable {
    case all, songs, albums, artists, playlists
    var id: String { rawValue }
    var title: LocalizedStringResource {
        switch self {
        case .all: "All"
        case .songs: "Songs"
        case .albums: "Albums"
        case .artists: "Artists"
        case .playlists: "Playlists"
        }
    }
}

enum LibrarySearchMatch: Identifiable {
    case song(DisplayableSong)
    case album(AlbumID3)
    case artist(ArtistID3)
    case playlist(Playlist)

    var id: String {
        switch self {
        case .song(let value): "song:\(value.id)"
        case .album(let value): "album:\(value.id)"
        case .artist(let value): "artist:\(value.id)"
        case .playlist(let value): "playlist:\(value.id)"
        }
    }

    var scope: LibrarySearchScope {
        switch self {
        case .song: .songs
        case .album: .albums
        case .artist: .artists
        case .playlist: .playlists
        }
    }

    var title: String {
        switch self {
        case .song(let value): value.title
        case .album(let value): value.name
        case .artist(let value): value.name
        case .playlist(let value): value.name
        }
    }

    var detail: String {
        switch self {
        case .song(let value): [value.artist, value.albumName].compactMap { $0 }.joined(separator: " ")
        case .album(let value): value.artist ?? ""
        case .artist: ""
        case .playlist(let value): value.comment ?? ""
        }
    }
}

/// Ranks existing catalogue matches without a second request. Stable ties keep the list from
/// moving as partial results arrive. Playlist matching uses the cached server-scoped list.
enum LibrarySearchRanking {
    static func matches(query: String, results: SearchResult3?, playlists: [Playlist]) -> [LibrarySearchMatch] {
        guard !normalized(query).isEmpty else { return [] }
        var values: [LibrarySearchMatch] = (results?.artist ?? [])
            .filter { ($0.albumCount ?? 0) > 0 }.map(LibrarySearchMatch.artist)
        values += (results?.album ?? []).map(LibrarySearchMatch.album)
        values += (results?.song ?? []).map { .song(DisplayableSong(from: $0)) }
        values += playlists.map(LibrarySearchMatch.playlist).filter { score($0, query: query) > 0 }
        var seen = Set<String>()
        return values.filter { seen.insert($0.id).inserted }.sorted { lhs, rhs in
            let a = score(lhs, query: query), b = score(rhs, query: query)
            if a != b { return a > b }
            let order = lhs.title.localizedStandardCompare(rhs.title)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }
    }

    static func score(_ match: LibrarySearchMatch, query: String) -> Int {
        let query = normalized(query)
        guard !query.isEmpty else { return 0 }
        let title = normalized(match.title)
        if title == query { return 1_000 }
        if title.hasPrefix(query) { return 800 }
        let tokens = query.split(separator: " ")
        if title.contains(query) { return 600 }
        if tokens.allSatisfy({ token in title.split(separator: " ").contains { $0.hasPrefix(token) } }) { return 500 }
        let combined = title + " " + normalized(match.detail)
        return tokens.allSatisfy { combined.contains($0) } ? 200 : 0
    }

    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
}
