import SwiftUI

private struct MinidiscPlayingAccentKey: EnvironmentKey {
    // Falls back to the standard brand accent when no dominant background is available.
    static let defaultValue: Color = MinidiscColors.accent
}

extension EnvironmentValues {
    /// Accent color for currently-playing indicators (title, bars, active transport buttons).
    /// Parent views with a dominant background should override this with
    /// `MinidiscColors.accentForeground(on: dominantColor)` so child components
    /// automatically stay WCAG-contrast-safe without prop drilling.
    var minidiscPlayingAccent: Color {
        get { self[MinidiscPlayingAccentKey.self] }
        set { self[MinidiscPlayingAccentKey.self] = newValue }
    }
}
