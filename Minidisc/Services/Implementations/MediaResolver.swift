import Foundation
import SwiftSonic
import OSLog

actor MediaResolver: MediaResolverProtocol {
    private let downloadService: any DownloadServiceProtocol
    private let audioStreamCache: any AudioStreamCacheProtocol
    private let serverService: any ServerServiceProtocol
    private let serverState: ServerState
    private let streamSettings: StreamSettings
    private let diagnostics: PlaybackDiagnostics?
    private var nextProbeID: UInt64 = 0
    private let songLookup: @Sendable (ServerConnection, String) async throws -> Void

    init(
        downloadService: any DownloadServiceProtocol,
        audioStreamCache: any AudioStreamCacheProtocol,
        serverService: any ServerServiceProtocol,
        serverState: ServerState,
        streamSettings: StreamSettings,
        diagnostics: PlaybackDiagnostics? = nil,
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
        self.diagnostics = diagnostics
        self.songLookup = songLookup
    }

    func availability(songId: String, serverId: UUID) async -> MediaAvailability {
        if await localSource(songId: songId, serverId: serverId) != nil {
            return .available
        }
        guard !Task.isCancelled,
              await MainActor.run(body: { serverState.isOnline }),
              let connection = try? await serverService.activeConnection(),
              connection.version.serverID == serverId else { return .unknown }

        nextProbeID &+= 1
        let probeID = nextProbeID
        let started = ProcessInfo.processInfo.systemUptime
        diagnostics?.record(.serverProbeStarted(request: probeID))
        let result: MediaAvailability
        var failure: PlaybackDiagnosticFailure?
        do {
            try await songLookup(connection, songId)
            result = .available
        } catch {
            result = Self.availability(after: error)
            failure = PlaybackDiagnosticFailure(error)
        }
        diagnostics?.record(.serverProbeCompleted(
            request: probeID, seconds: ProcessInfo.processInfo.systemUptime - started,
            availability: result, failure: failure
        ))
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

    func localSource(songId: String, serverId: UUID) async -> MediaSource? {
        if let url = await downloadService.downloadedURL(forSongId: songId, serverId: serverId) {
            Logger.resolver.debug("Resolved '\(songId, privacy: .public)' from permanent download.")
            return .downloaded(url)
        }

        if let url = await audioStreamCache.cachedURL(forSongId: songId, serverId: serverId) {
            Logger.resolver.debug("Resolved '\(songId, privacy: .public)' from cache.")
            return .cached(url)
        }
        return nil
    }

    func resolve(songId: String, serverId: UUID) async throws -> MediaSource {
        if let source = await localSource(songId: songId, serverId: serverId) {
            return source
        }

        let isOnline = await MainActor.run { serverState.isOnline }
        guard isOnline else {
            Logger.resolver.warning("'\(songId, privacy: .public)' not available offline.")
            throw MinidiscError.offlineUnavailable(songId: songId)
        }

        let connection = try await serverService.activeConnection()
        guard connection.version.serverID == serverId else { throw CancellationError() }
        let client = connection.makeSwiftSonicClient()
        let quality = await MainActor.run { streamSettings.currentQuality }
        // An estimated HTTP length can cut a transcode short or leave AVPlayer waiting for
        // bytes that do not exist. The library supplies the track duration independently.
        guard let streamURL = client.streamURL(
            id: songId,
            maxBitRate: quality.subsonicMaxBitRate,
            format: quality.subsonicFormat,
            estimateContentLength: false
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
