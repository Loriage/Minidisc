// Minidisc — Music client for Subsonic/OpenSubsonic servers
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

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

    init(
        downloadService: any DownloadServiceProtocol,
        audioStreamCache: any AudioStreamCacheProtocol,
        serverService: any ServerServiceProtocol,
        serverState: ServerState,
        streamSettings: StreamSettings
    ) {
        self.downloadService = downloadService
        self.audioStreamCache = audioStreamCache
        self.serverService = serverService
        self.serverState = serverState
        self.streamSettings = streamSettings
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
        let client = try await serverService.makeSwiftSonicClient()
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
        let creds = try await serverService.activeCredentials()
        Logger.resolver.debug("Resolved '\(songId, privacy: .public)' as stream.")
        return .stream(streamURL, customHeaders: creds.customHeaders)
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

        let activeServerURL = await MainActor.run {
            serverState.activeServer.flatMap { URL(string: $0.baseURL) }
        }
        let customHeaders: [String: String]
        if let activeServerURL, Self.isSameOrigin(url, activeServerURL) {
            customHeaders = try await serverService.activeCredentials().customHeaders
        } else {
            // Internet-radio URLs commonly point at a third-party host. Cloudflare/access headers
            // belong to the Subsonic origin and must never be forwarded across origins.
            customHeaders = [:]
        }
        Logger.resolver.debug("Resolved radio '\(station.id, privacy: .public)' as live stream.")
        return .liveStream(url, customHeaders: customHeaders, stationId: station.id)
    }

    nonisolated static func isSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let lhsScheme = lhs.scheme?.lowercased(),
              let rhsScheme = rhs.scheme?.lowercased(),
              let lhsHost = lhs.host?.lowercased(),
              let rhsHost = rhs.host?.lowercased() else { return false }
        func effectivePort(_ url: URL, scheme: String) -> Int? {
            url.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : nil)
        }
        return lhsScheme == rhsScheme
            && lhsHost == rhsHost
            && effectivePort(lhs, scheme: lhsScheme) == effectivePort(rhs, scheme: rhsScheme)
    }
}
