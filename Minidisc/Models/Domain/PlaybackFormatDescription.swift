import Foundation

/// The player's format line: where the audio comes from, its format and bit rate.
/// For a transcoded stream it describes what the server was asked to send, not the source file.
nonisolated struct PlaybackFormatDescription: Equatable, Sendable {
    let systemImage: String
    let parts: [String]

    var text: String { parts.joined(separator: " · ") }

    init?(track: DisplayableSong?, source: PlaybackSourceKind?, isCellular: Bool) {
        guard let track, let source else { return nil }

        var format = track.audioFormat?.uppercased()
        var bitRate = track.bitRate
        let sourceLabel: String

        switch source {
        case .liveStream:
            return nil
        case .localFile:
            systemImage = "folder"
            sourceLabel = String(localized: "On Device")
        case .downloaded:
            systemImage = "arrow.down.circle"
            sourceLabel = String(localized: "Downloaded")
        case .cached:
            systemImage = "internaldrive"
            sourceLabel = String(localized: "Cached")
        case .stream(let transcodedFormat, let maxBitRate):
            systemImage = isCellular ? "cellularbars" : "wifi"
            if source.isTranscoded {
                sourceLabel = String(localized: "Transcoding")
                if let transcodedFormat { format = transcodedFormat.uppercased() }
                if let maxBitRate { bitRate = min(maxBitRate, bitRate ?? maxBitRate) }
            } else {
                sourceLabel = String(localized: "Streaming")
            }
        }

        var parts = [sourceLabel]
        if let format, !format.isEmpty { parts.append(format) }
        if let bitRate, bitRate > 0 { parts.append(String(localized: "\(bitRate.formatted(.number.grouping(.never))) kbps")) }
        self.parts = parts
    }
}
