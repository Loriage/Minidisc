import Foundation

nonisolated enum ValidationStatus: Sendable, Equatable {
    case unknown
    case validating
    case valid
    case invalid(reason: String)
}

nonisolated struct ListenBrainzSnapshot: Sendable, Equatable {
    let isEnabled: Bool
    let username: String?
    let validationStatus: ValidationStatus
}
