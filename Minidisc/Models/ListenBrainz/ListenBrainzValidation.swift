import Foundation

nonisolated struct ListenBrainzValidation: Sendable {
    let isValid: Bool
    let username: String?
}

/// Immutable snapshot of scrobbling configuration at a given point in time.
/// Separate from ListenBrainzSnapshot (recommendations) — token-based auth vs username-based.
nonisolated struct ScrobblingSnapshot: Sendable, Equatable {
    let isEnabled: Bool
    /// Username returned by /1/validate-token and persisted to Keychain for display on restart.
    let username: String?
    let serverRootURL: String
    let validationStatus: ValidationStatus
}
