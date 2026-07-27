import Foundation

nonisolated enum LyricsError: Error, Equatable {
    case notSupportedByServer
    case notFound
    case networkError(underlying: String)
    case cacheCorrupted
}
