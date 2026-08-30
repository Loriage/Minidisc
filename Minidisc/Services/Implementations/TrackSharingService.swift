import Foundation
import OSLog
import SwiftSonic

nonisolated enum PreparedTrackShare: Hashable, Identifiable, Sendable {
    case publicLink(URL)
    case metadata(String)

    var id: Self { self }
}

/// Prepares the best content available when the user explicitly shares a track.
/// Navidrome links are public; local metadata is the safe fallback for unsupported or offline servers.
actor TrackSharingService {
    typealias PublicLinkProvider = @Sendable (DisplayableSong) async throws -> URL?

    private let publicLinkProvider: PublicLinkProvider

    init(serverService: any ServerServiceProtocol) {
        publicLinkProvider = { song in
            let connection = try await serverService.activeConnection()
            let client = connection.makeSwiftSonicClient()
            let user = try await client.getUser(username: connection.server.username)
            guard user.shareRole else { return nil }

            let shares = try await client.createShare(ids: [song.id])
            guard let rawURL = shares.first?.url,
                  let url = URL(string: rawURL),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "https" || scheme == "http",
                  url.host != nil else { return nil }
            return url
        }
    }

    init(publicLinkProvider: @escaping PublicLinkProvider) {
        self.publicLinkProvider = publicLinkProvider
    }

    func prepareShare(
        for song: DisplayableSong,
        serverIsReachable: Bool
    ) async -> PreparedTrackShare? {
        let metadata = PreparedTrackShare.metadata(Self.metadataText(for: song))
        guard serverIsReachable else { return metadata }

        do {
            guard let url = try await publicLinkProvider(song) else { return metadata }
            return .publicLink(url)
        } catch is CancellationError {
            return nil
        } catch {
            Logger.server.info("[SHARE] Public link unavailable; using local metadata")
            return metadata
        }
    }

    nonisolated static func metadataText(for song: DisplayableSong) -> String {
        let trimmedTitle = song.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmedTitle.isEmpty ? song.title : trimmedTitle
        let subtitle = [song.artist, song.albumName]
            .compactMap { value -> String? in
                guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " · ")

        if subtitle.isEmpty {
            return "♫ \(title)"
        }
        return "♫ \(title)\n\(subtitle)"
    }
}
