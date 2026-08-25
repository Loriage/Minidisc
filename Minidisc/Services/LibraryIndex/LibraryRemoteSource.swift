import Foundation
import SwiftSonic

nonisolated struct LibraryRemoteScanStatus: Sendable, Equatable {
    let isScanning: Bool
    let lastCompletedAt: Date?
}

/// The server operations needed to populate and repair the persistent library index.
/// A dedicated interface keeps synchronizer tests independent from the full playback library module.
nonisolated protocol LibraryRemoteSource: Sendable {
    func activeServerID() async throws -> UUID
    func isOnline() async -> Bool
    func search(_ query: String, serverID: UUID) async throws -> SearchResult3
    func artists(serverID: UUID) async throws -> [ArtistIndex]
    func artist(id: String, serverID: UUID) async throws -> ArtistID3
    func album(id: String, serverID: UUID) async throws -> AlbumID3
    func recentlyAddedAlbums(size: Int, serverID: UUID) async throws -> [AlbumID3]
    func albumsPage(offset: Int, count: Int, serverID: UUID) async throws -> [AlbumID3]
    func songsPage(offset: Int, count: Int, serverID: UUID) async throws -> [Song]
    func playlists(serverID: UUID) async throws -> [Playlist]
    func playlist(id: String, serverID: UUID) async throws -> PlaylistWithSongs
    func scanStatus(serverID: UUID) async throws -> LibraryRemoteScanStatus?
}

extension LibraryRemoteSource {
    /// Older Subsonic servers may not expose scan metadata. The catalogue then uses
    /// its conservative time-based refresh policy instead.
    func scanStatus(serverID: UUID) async throws -> LibraryRemoteScanStatus? { nil }
}

/// SwiftSonic adapter for index-oriented catalogue reads. It validates the active
/// server on every page so a server switch cannot write one server's rows under another ID.
actor SwiftSonicLibrarySource: LibraryRemoteSource {
    private let serverService: any ServerServiceProtocol
    private var cachedClient: SwiftSonicClient?
    private var cachedVersion: ServerConnection.Version?

    init(serverService: any ServerServiceProtocol) {
        self.serverService = serverService
    }

    func activeServerID() async throws -> UUID {
        try await serverService.activeConnection().version.serverID
    }

    func isOnline() async -> Bool {
        await MainActor.run { serverService.state.isOnline }
    }

    func search(_ query: String, serverID: UUID) async throws -> SearchResult3 {
        try await client(for: serverID).search3(query)
    }

    func artists(serverID: UUID) async throws -> [ArtistIndex] {
        try await client(for: serverID).getArtists()
    }

    func artist(id: String, serverID: UUID) async throws -> ArtistID3 {
        try await client(for: serverID).getArtist(id: id)
    }

    func album(id: String, serverID: UUID) async throws -> AlbumID3 {
        try await client(for: serverID).getAlbum(id: id)
    }

    func recentlyAddedAlbums(size: Int, serverID: UUID) async throws -> [AlbumID3] {
        try await client(for: serverID).getAlbumList2(type: .newest, size: size)
    }

    func albumsPage(offset: Int, count: Int, serverID: UUID) async throws -> [AlbumID3] {
        try await client(for: serverID).getAlbumList2(
            type: .alphabeticalByName,
            size: count,
            offset: offset
        )
    }

    func songsPage(offset: Int, count: Int, serverID: UUID) async throws -> [Song] {
        try await client(for: serverID).search3(
            "",
            artistCount: 0,
            albumCount: 0,
            songCount: count,
            songOffset: offset
        ).song ?? []
    }

    func playlists(serverID: UUID) async throws -> [Playlist] {
        try await client(for: serverID).getPlaylists()
    }

    func playlist(id: String, serverID: UUID) async throws -> PlaylistWithSongs {
        try await client(for: serverID).getPlaylist(id: id)
    }

    func scanStatus(serverID: UUID) async throws -> LibraryRemoteScanStatus? {
        let status = try await client(for: serverID).getScanStatus()
        return LibraryRemoteScanStatus(
            isScanning: status.scanning,
            lastCompletedAt: status.lastScan
        )
    }

    private func client(for expectedServerID: UUID) async throws -> SwiftSonicClient {
        let connection = try await serverService.activeConnection()
        guard connection.version.serverID == expectedServerID else {
            throw MinidiscError.serverNotConfigured
        }
        if cachedVersion == connection.version, let cachedClient {
            return cachedClient
        }
        let client = connection.makeSwiftSonicClient()
        cachedVersion = connection.version
        cachedClient = client
        return client
    }
}
