import Foundation

nonisolated enum ValidationStatus: Sendable, Equatable {
    case unknown
    case validating
    case valid
    case invalid(reason: String)
}

/// Immutable snapshot of ListenBrainzService state at a given point in time.
/// Safe to pass across actor boundaries.
nonisolated struct ListenBrainzSnapshot: Sendable, Equatable {
    let isEnabled: Bool
    let username: String?
    let validationStatus: ValidationStatus
}
