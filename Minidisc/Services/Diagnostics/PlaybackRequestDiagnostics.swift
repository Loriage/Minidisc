import Foundation
import SwiftSonic

nonisolated struct PlaybackRequestDiagnostics: Sendable, Equatable {
    enum Transport: String, Sendable { case local, http, https, other }
    enum Format: String, Sendable { case serverDefault, raw, mp3, aac, opus, flac, alac, wav, aiff, m4a, ogg, other }

    let transport: Transport
    let requestedFormat: Format
    let maxBitRate: Int?
    let estimateContentLength: Bool?
    let timeOffset: Double?
    let headerCount: Int
    let localContainerHint: Format?

    init(url: URL, headerCount: Int) {
        transport = url.isFileURL ? .local : Transport(rawValue: url.scheme?.lowercased() ?? "") ?? .other
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        requestedFormat = value("format").map { Format(rawValue: $0.lowercased()) ?? .other } ?? .serverDefault
        maxBitRate = value("maxBitRate").flatMap(Int.init).flatMap { (0...1_000_000).contains($0) ? $0 : nil }
        estimateContentLength = value("estimateContentLength").flatMap { $0 == "true" ? true : ($0 == "false" ? false : nil) }
        timeOffset = value("timeOffset").flatMap(Double.init).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.headerCount = headerCount
        localContainerHint = url.isFileURL ? Format(rawValue: url.pathExtension.lowercased()) ?? .other : nil
    }

    var description: String {
        if transport == .local {
            return "transport=local container-hint=\(localContainerHint?.rawValue ?? "other") network-request=false"
        }
        return "transport=\(transport.rawValue) requested-format=\(requestedFormat.rawValue) max-kbps=\(maxBitRate.map(String.init) ?? "not-specified") estimated-length=\(estimateContentLength.map(String.init) ?? "not-specified") offset-s=\(timeOffset.map { String(format: "%.2f", $0) } ?? "not-specified") header-count=\(headerCount)\n    Actual response format is not inferred from request parameters."
    }
}

/// Response bodies, endpoint strings and server error messages are intentionally discarded.
nonisolated struct PlaybackDiagnosticFailure: Sendable, Equatable {
    enum Kind: String, Sendable { case http, subsonic, network, decoding, configuration, redirectBlocked, timeout, offline, mediaUnavailable, audioUnavailable, seekFailed, other }
    let kind: Kind
    let status: Int?
    let codes: AudioEngineFailure

    init(_ error: any Error) {
        var kind: Kind = .other
        var status: Int?
        var underlying: any Error = error
        for _ in 0..<5 {
            guard let wrapper = underlying as? MinidiscError else { break }
            switch wrapper {
            case .connectionFailed(let nested), .cacheStorageFailed(let nested), .downloadFailed(_, let nested):
                underlying = nested
            default: break
            }
        }
        if let error = underlying as? MinidiscError {
            switch error {
            case .timeout: kind = .timeout
            case .offlineUnavailable: kind = .offline
            case .mediaNotFound: kind = .mediaUnavailable
            case .audioSystemUnavailable: kind = .audioUnavailable
            case .playbackPositionUnavailable: kind = .seekFailed
            default: break
            }
        }
        if let error = underlying as? SwiftSonicError {
            switch error {
            case .httpError(let code, _, _): kind = .http; status = code
            case .rateLimited: kind = .http; status = 429
            case .api(let detail): kind = .subsonic; status = detail.code.rawValue
            case .network(let error): kind = .network; underlying = error
            case .decoding: kind = .decoding
            case .invalidConfiguration: kind = .configuration
            case .insecureRedirect: kind = .redirectBlocked
            }
        } else if (underlying as NSError).domain == NSURLErrorDomain {
            kind = .network
        }
        self.kind = kind
        self.status = status
        codes = AudioEngineFailure(error: underlying)
    }

    private var statusMeaning: String {
        guard kind == .http, let status else { return "n/a" }
        return switch status {
        case 401: "authentication-required"
        case 403: "access-denied"
        case 404: "http-resource-not-found"
        case 408, 504: "request-or-gateway-timeout"
        case 416: "range-not-satisfiable"
        case 429: "rate-limited"
        case 500: "server-error"
        case 502: "bad-gateway"
        case 503: "service-unavailable"
        default: "http-response"
        }
    }

    var description: String {
        "kind=\(kind.rawValue) status=\(status.map(String.init) ?? "n/a") status-meaning=\(statusMeaning) codes=\(codes.diagnosticDescription) meaning=\(codes.diagnosticMeaning)"
    }
}

nonisolated struct PlaybackDiagnosticSettings: Sendable {
    let wifiQuality: StreamQuality
    let cellularQuality: StreamQuality
    let selectedQuality: StreamQuality
    let offlineMode: Bool
    let cacheFormat: CacheFormat
    let cacheOverCellular: Bool
    let cacheCapacityMB: Int
    let offlineFavorites: Bool
    let crossfade: CrossfadeConfig
    let replayGain: ReplayGainConfig

    var description: String {
        [
            "Quality: wifi=\(wifiQuality.rawValue) cellular=\(cellularQuality.rawValue) selected-now=\(selectedQuality.rawValue)",
            "Storage: offline-mode=\(offlineMode) cache-format=\(cacheFormat.rawValue) cache-cellular=\(cacheOverCellular) cache-limit-MB=\(cacheCapacityMB) offline-favorites=\(offlineFavorites)",
            "Crossfade: requested-seconds=\(crossfade.duration) preserve-gapless=\(crossfade.disableForGapless); AirPlay disables overlap",
            "ReplayGain: enabled=\(replayGain.enabled) mode=\(replayGain.mode.rawValue) preamp-dB=\(replayGain.preAmp) prevent-clipping=\(replayGain.preventClipping)"
        ].joined(separator: "\n")
    }
}
