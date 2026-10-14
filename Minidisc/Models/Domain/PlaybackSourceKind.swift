import Foundation

/// Where the current track's audio comes from, as shown on the player ("Download", "Streaming").
nonisolated enum PlaybackSourceKind: Equatable, Sendable {
    case localFile
    case downloaded
    case cached
    /// `transcodedFormat` / `maxBitRate` are what the stream URL asked the server for; `nil` means original.
    case stream(transcodedFormat: String?, maxBitRate: Int?)
    case liveStream

    init(_ source: MediaSource) {
        switch source {
        case .localFile: self = .localFile
        case .downloaded: self = .downloaded
        case .cached: self = .cached
        case .liveStream: self = .liveStream
        case .stream(let url, _):
            // Only the transcoding parameters are read; the URL also carries auth tokens.
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let format = items.first { $0.name == "format" }?.value.flatMap { $0 == "raw" ? nil : $0 }
            let maxBitRate = items.first { $0.name == "maxBitRate" }?.value.flatMap(Int.init)
            self = .stream(transcodedFormat: format, maxBitRate: maxBitRate == 0 ? nil : maxBitRate)
        }
    }

    var isTranscoded: Bool {
        if case .stream(let format, let maxBitRate) = self { return format != nil || maxBitRate != nil }
        return false
    }
}
