import Foundation

nonisolated struct ConnectionErrorPresentation: Sendable, Equatable {
    let title: LocalizedStringResource
    let description: LocalizedStringResource
    let technicalCode: String
}
