import Foundation

nonisolated enum MediaSource: Sendable {
    case localFile(LocalFileAccess)
    case downloaded(URL)
    case cached(URL)
    case seekBuffer(TranscodedSeekFile)
    /// Remote stream of a finite-duration song. Custom headers must be injected
    /// into every request to reach Cloudflare-protected (or other reverse-proxy) hosts.
    case stream(URL, customHeaders: [String: String])
    /// Live audio stream (Internet Radio Station). Infinite-duration, not scrubbable,
    /// not cacheable. Custom headers may be required when the radio host is reached
    /// via the user's Navidrome reverse proxy.
    case liveStream(URL, customHeaders: [String: String], stationId: String)

    var url: URL {
        switch self {
        case .localFile(let access):
            return access.url
        case .seekBuffer(let file):
            return file.url
        case .downloaded(let url), .cached(let url):
            return url
        case .stream(let url, _), .liveStream(let url, _, _):
            return url
        }
    }

    var customHeaders: [String: String] {
        switch self {
        case .downloaded, .cached, .localFile, .seekBuffer:
            return [:]
        case .stream(_, let headers), .liveStream(_, let headers, _):
            return headers
        }
    }

    var isLiveStream: Bool {
        if case .liveStream = self { return true }
        return false
    }

    var needsCompleteFileForSeeking: Bool {
        guard case .stream(let url, _) = self else { return false }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return query.contains { $0.name == "format" && $0.value == "mp3" }
    }
}
