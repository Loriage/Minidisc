import Foundation
import CryptoKit
import SwiftSonic

nonisolated enum MusicIntentKind: String, Codable, Sendable {
    case song, album, artist, playlist
}

nonisolated struct MusicIntentID: Codable, Hashable, Sendable {
    let scope: String
    let kind: MusicIntentKind
    let resourceID: String

    var rawValue: String {
        "v1." + scope + "." + kind.rawValue + "." + Data(resourceID.utf8).base64EncodedString()
    }

    init(scope: String, kind: MusicIntentKind, resourceID: String) {
        self.scope = scope
        self.kind = kind
        self.resourceID = resourceID
    }

    init?(rawValue: String) {
        let parts = rawValue.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "v1", parts[1].count == 64,
              let kind = MusicIntentKind(rawValue: String(parts[2])),
              let data = Data(base64Encoded: String(parts[3])),
              let id = String(data: data, encoding: .utf8), !id.isEmpty else { return nil }
        self.init(scope: String(parts[1]), kind: kind, resourceID: id)
    }

    /// Stable across reinstalls; account and endpoint separation prevents cross-server ID collisions.
    static func scope(baseURL: String, username: String) -> String {
        var url = URLComponents(string: baseURL)
        let scheme = url?.scheme?.lowercased()
        let host = url?.host?.lowercased()
        url?.scheme = scheme
        url?.host = host
        url?.user = nil
        url?.password = nil
        url?.fragment = nil
        if (url?.scheme == "https" && url?.port == 443) || (url?.scheme == "http" && url?.port == 80) {
            url?.port = nil
        }
        while url?.path.hasSuffix("/") == true { url?.path.removeLast() }
        let endpoint = url?.string ?? baseURL
        let data = Data((endpoint + "\n" + username).utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated struct MusicIntentRecord: Sendable, Identifiable {
    let reference: MusicIntentID
    let title: String
    var subtitle: String = ""
    var song: DisplayableSong?
    var id: String { reference.rawValue }

    init(scope: String, song: Song) {
        reference = .init(scope: scope, kind: .song, resourceID: song.id)
        title = song.title
        subtitle = song.artist ?? ""
        self.song = DisplayableSong(from: song)
    }

    init(scope: String, album: AlbumID3) {
        reference = .init(scope: scope, kind: .album, resourceID: album.id)
        title = album.name
        subtitle = album.artist ?? ""
    }

    init(scope: String, artist: ArtistID3) {
        reference = .init(scope: scope, kind: .artist, resourceID: artist.id)
        title = artist.name
    }

    init(scope: String, playlist: Playlist) {
        reference = .init(scope: scope, kind: .playlist, resourceID: playlist.id)
        title = playlist.name
        subtitle = playlist.owner ?? ""
    }
}

nonisolated enum MusicIntentError: Error, CustomLocalizedStringResourceConvertible {
    case noServer, differentServer, unavailable, empty, moodUnavailable, nothingToResume

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noServer: "Open Minidisc and connect to your music server first."
        case .differentServer: "Select the server used by this shortcut in Minidisc, then try again."
        case .unavailable: "This music is unavailable. Check your connection or downloads in Minidisc."
        case .empty: "There are no playable tracks in this selection."
        case .moodUnavailable: "This Mood playlist is unavailable. Open Discover in Minidisc to check your Moods."
        case .nothingToResume: "There is no music to resume. Choose music in Minidisc first."
        }
    }
}
