import Foundation

nonisolated enum PlaybackWaitingReason: Sendable, Equatable {
    case loading
    case buffering
    case reconnecting

    var title: String {
        switch self {
        case .loading: String(localized: "Connecting…")
        case .buffering: String(localized: "Buffering…")
        case .reconnecting: String(localized: "Reconnecting…")
        }
    }
}

nonisolated enum PlaybackState: Sendable, Equatable {
    case idle
    case loading
    case playing
    case paused
    case error(MinidiscError)

    nonisolated static func == (lhs: PlaybackState, rhs: PlaybackState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.loading, .loading), (.playing, .playing), (.paused, .paused):
            return true
        case (.error, .error):
            return true
        default:
            return false
        }
    }
}
