import SwiftUI

private struct MinidiscPlayingAccentKey: EnvironmentKey {
    static let defaultValue: Color = MinidiscColors.accent
}

extension EnvironmentValues {
    /// Override with accentForeground(on:) when indicators sit on artwork-derived backgrounds.
    var minidiscPlayingAccent: Color {
        get { self[MinidiscPlayingAccentKey.self] }
        set { self[MinidiscPlayingAccentKey.self] = newValue }
    }
}
