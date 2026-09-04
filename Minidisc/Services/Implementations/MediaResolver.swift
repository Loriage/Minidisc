import Foundation
import SwiftSonic
import OSLog

/// Single entry point for obtaining a playable URL for a given song.
/// Resolution order: downloaded → cached → stream.
/// PlayerService always calls this — it never contacts SwiftSonic directly.
actor MediaResolver: MediaResolverProtocol {
    private let downloadService: any DownloadServiceProtocol
    private let audioStreamCache: any AudioStreamCacheProtocol
    private let serverService: any ServerServiceProtocol
    private let serverState: ServerState
    private let streamSettings: StreamSettings
    private let songLookup: @Sendable (ServerConnection, String) async throws -> Void

    init(
        downloadService: any DownloadServiceProtocol,
        audioStreamCache: any AudioStreamCacheProtocol,
        serverService: any ServerServiceProtocol,
        serverState: ServerState,
        streamSettings: StreamSettings,
        songLookup: @escaping @Sendable (ServerConnection, String) async throws -> Void = { connection, id in
            // PlayerService owns retries. A diagnostic lookup must not introduce its own
            // retry loop in front of each stream rebuild.
            _ = try await connection.makeSwiftSonicClient(requestTimeout: 8, retryPolicy: .none).getSong(id: id)
        }
    ) {
        self.downloadService = downloadService
        self.audioStreamCache = audioStreamCache
        self.serverService = serverService
        self.serverState = serverState
        self.streamSettings = streamSettings
        self.songLookup = songLookup
    }

    func availability(songId: String, serverId: UUID) async -> MediaAvailability {
        if await downloadService.downloadedURL(forSongId: songId, serverId: serverId) != nil {
            return .available
        }
        if await audioStreamCache.cachedURL(forSongId: songId, serverId: serverId) != nil {
            return .available
        }
        guard !Task.isCancelled,
              await MainActor.run(body: { serverState.isOnline }),
              let connection = try? await serverService.activeConnection(),
              connection.version.serverID == serverId else { return .unknown }

        let result: MediaAvailability
        do {
            try await songLookup(connection, songId)
            result = .available
        } catch {
            result = Self.availability(after: error)
        }
        guard !Task.isCancelled,
              await serverService.activeConnectionVersion() == connection.version else { return .unknown }
        return result
    }

    nonisolated static func availability(after error: any Error) -> MediaAvailability {
        // An HTTP 404 can be a reverse proxy or a missing API endpoint. Only Subsonic's
        // structured "not found" response for getSong confirms that this song disappeared.
        if let error = error as? SwiftSonicError,
           case .api(let detail) = error,
           detail.code == .notFound,
           detail.endpoint == "getSong" {
            return .missing
        }
        return .unknown
    }

    func resolve(songId: String, serverId: UUID) async throws -> MediaSource {
        // 1. Permanent download — always preferred, works offline.
        if let url = await downloadService.downloadedURL(forSongId: songId, serverId: serverId) {
            Logger.resolver.debug("Resolved '\(songId, privacy: .public)' from permanent download.")
            return .downloaded(url)
        }

        // 2. Ephemeral cache — no network needed.
        if let url = await audioStreamCache.cachedURL(forSongId: songId, serverId: serverId) {
            Logger.resolver.debug("Resolved '\(songId, privacy: .public)' from cache.")
            return .cached(url)
        }

        // 3. Offline guard — no local copy available, device has no connectivity.
        let isOnline = await MainActor.run { serverState.isOnline }
        guard isOnline else {
            Logger.resolver.warning("'\(songId, privacy: .public)' not available offline.")
            throw MinidiscError.offlineUnavailable(songId: songId)
        }

        // 4. Stream. Custom headers injected so AVPlayer reaches Cloudflare-protected hosts.
        // AVURLAssetHTTPHeaderFieldsKey is used at the PlayerService call site.
        // TODO(v1.x): trigger background cache write alongside the stream.
        let connection = try await serverService.activeConnection()
        let client = connection.makeSwiftSonicClient()
        // Live-stream quality: `.original` (default) streams the untouched file; a transcoded
        // option asks the server to re-encode to a lighter codec so on-device decode can't starve
        // the audio thread under a CPU spike (the crackle fix). The tier follows the current
        // network (Wi-Fi vs cellular).
        let quality = await MainActor.run { streamSettings.currentQuality }
        // `estimateContentLength` asks the server to send a Content-Length for a transcoded stream.
        // Without it the response is chunked, AVPlayer cannot work out the track length, and the
        // player falls back to the library metadata: the counter freezes at the advertised end while
        // the audio keeps going, and the crossfade window — armed off that same length — never opens.
        guard let streamURL = client.streamURL(
            id: songId,
            maxBitRate: quality.subsonicMaxBitRate,
            format: quality.subsonicFormat,
            estimateContentLength: true
        ) else {
            throw MinidiscError.mediaNotFound(songId: songId)
        }
        Logger.resolver.debug("Resolved '\(songId, privacy: .public)' as stream.")
        return .stream(
            streamURL,
            customHeaders: connection.authorizationHeaders(for: streamURL)
        )
    }

    func resolveRadio(_ station: InternetRadioStation) async throws -> MediaSource {
        guard let url = URL(string: station.streamUrl) else {
            Logger.resolver.error("Invalid stream URL for radio station '\(station.id, privacy: .public)': \(station.streamUrl, privacy: .private)")
            throw MinidiscError.mediaNotFound(songId: station.id)
        }

        let isOnline = await MainActor.run { serverState.isOnline }
        guard isOnline else {
            Logger.resolver.warning("Radio '\(station.id, privacy: .public)' not available offline.")
            throw MinidiscError.offlineUnavailable(songId: station.id)
        }

        let connection = try await serverService.activeConnection()
        // Internet-radio URLs commonly point at a third-party host. ServerConnection refuses to
        // forward reverse-proxy authorization across origins.
        let customHeaders = connection.authorizationHeaders(for: url)
        Logger.resolver.debug("Resolved radio '\(station.id, privacy: .public)' as live stream.")
        return .liveStream(url, customHeaders: customHeaders, stationId: station.id)
    }

    nonisolated static func isSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        ServerConnection.isSameOrigin(lhs, rhs)
    }
}
