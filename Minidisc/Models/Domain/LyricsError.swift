import Foundation

nonisolated enum LyricsError: Error, Equatable, Sendable {
    case notSupportedByServer
    case notFound
    case networkError(underlying: String)
    case cacheCorrupted
}
