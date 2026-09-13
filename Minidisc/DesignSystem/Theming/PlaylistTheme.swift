import SwiftUI

/// Resolved artwork color and foreground colors shared by detail-page content and backgrounds.
struct PlaylistTheme: Equatable, Sendable {
    /// Base theme color. `.clear` = not resolved yet → system-adaptive fallback (no blend).
    let dominantColor: Color

    init(dominantColor: Color) {
        self.dominantColor = dominantColor
    }

    var isThemed: Bool { dominantColor != .clear }
    var isLight: Bool { isThemed && dominantColor.luminance > 0.6 }

    // Use perceived luminance, matching player controls. Fall back to system colors until resolved.
    var contentColor: Color { isThemed ? (isLight ? .black : .white) : .primary }
    var secondaryContentColor: Color {
        isThemed ? (isLight ? Color.black.opacity(0.7) : Color.white.opacity(0.7)) : .secondary
    }
}
