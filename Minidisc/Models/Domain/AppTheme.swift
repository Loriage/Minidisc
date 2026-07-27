import SwiftUI

/// User-selectable appearance. Persists via `@AppStorage("minidisc.appTheme")`, read both by the
/// settings picker and by `MainTabView`, which applies it to the whole tab hierarchy.
nonisolated enum AppTheme: String, CaseIterable, Sendable {
    case system
    case light
    case dark

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// `nil` hands the choice back to the system setting.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
