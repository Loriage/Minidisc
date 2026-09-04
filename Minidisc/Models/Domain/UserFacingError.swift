import Foundation
import SwiftSonic

nonisolated enum UserFacingError: LocalizedError, Identifiable, Sendable {
    case noNetwork
    case serverUnreachable
    case authenticationFailed
    case contentUnavailableOffline
    case contentRemoved
    case downloadFailed
    case playbackFailed
    case syncFailed
    case unexpected

    var id: String {
        switch self {
        case .noNetwork: "noNetwork"
        case .serverUnreachable: "serverUnreachable"
        case .authenticationFailed: "authenticationFailed"
        case .contentUnavailableOffline: "contentUnavailableOffline"
        case .contentRemoved: "contentRemoved"
        case .downloadFailed: "downloadFailed"
        case .playbackFailed: "playbackFailed"
        case .syncFailed: "syncFailed"
        case .unexpected: "unexpected"
        }
    }

    var errorDescription: String? {
        switch self {
        case .noNetwork: String(localized: "No internet connection.")
        case .serverUnreachable: String(localized: "Couldn't reach your server.")
        case .authenticationFailed: String(localized: "Authentication failed.")
        case .contentUnavailableOffline: String(localized: "This content isn't available offline.")
        case .contentRemoved: String(localized: "This content is no longer available on the server.")
        case .downloadFailed: String(localized: "Download failed.")
        case .playbackFailed: String(localized: "Couldn't play this track.")
        case .syncFailed: String(localized: "Couldn't sync with your server.")
        case .unexpected: String(localized: "Something went wrong.")
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .noNetwork: String(localized: "Check your connection and try again.")
        case .serverUnreachable: String(localized: "Make sure your server is running and reachable.")
        case .authenticationFailed: String(localized: "Verify your credentials in Settings.")
        case .contentUnavailableOffline: String(localized: "Download this content first, or reconnect to your server.")
        case .contentRemoved: String(localized: "Choose another track or a downloaded copy.")
        case .downloadFailed: String(localized: "Check your connection and storage, then try again.")
        case .playbackFailed: String(localized: "Try again or skip to another track.")
        case .syncFailed: String(localized: "Check your connection and try syncing again.")
        case .unexpected: nil
        }
    }

    var displayMessage: String {
        [errorDescription, recoverySuggestion].compactMap { $0 }.joined(separator: " ")
    }

    static func from(_ error: any Error) -> UserFacingError {
        if let error = error as? UserFacingError { return error }
        if let error = error as? SwiftSonicError {
            if error.isAuthenticationFailure { return .authenticationFailed }
            if case .network(let underlying) = error { return from(underlying) }
            if case .api(let response) = error, response.code == .notFound { return .contentRemoved }
            return .serverUnreachable
        }
        if error is CancellationError { return .unexpected }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return .noNetwork
            case .userAuthenticationRequired:
                return .authenticationFailed
            default:
                return .serverUnreachable
            }
        }
        if let minidiscError = error as? MinidiscError {
            switch minidiscError {
            case .offlineUnavailable:
                return .contentUnavailableOffline
            case .downloadFailed:
                return .downloadFailed
            case .mediaNotFound:
                return .contentRemoved
            case .timeout:
                return .serverUnreachable
            case .connectionFailed, .serverNotConfigured, .serverNotFound:
                return .serverUnreachable
            default:
                return .unexpected
            }
        }
        return .unexpected
    }

    static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let error = error as? URLError { return error.code == .cancelled }
        if let error = error as? SwiftSonicError, case .network(let underlying) = error {
            return underlying.code == .cancelled
        }
        return false
    }
}
