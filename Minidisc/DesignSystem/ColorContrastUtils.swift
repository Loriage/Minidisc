// Minidisc — Music client for Subsonic/OpenSubsonic servers
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

extension MinidiscColors {
    // Orange-red brand variants, chosen to match the old violets' luminances so the WCAG
    // decision boundaries below are unchanged — only the hue flips.
    // Light (#FF6242): WCAG relative luminance ≈ 0.304
    // Dark  (#8F2408): WCAG relative luminance ≈ 0.071
    private static let accentFgLight = Color(hex: "#FF6242")
    private static let accentFgDark  = Color(hex: "#8F2408")
    private static let luminanceFgLight: Double = 0.304
    private static let luminanceFgDark:  Double = 0.071
    static var contrastThreshold: Double = 3.0

    /// Returns whichever accentForeground variant achieves WCAG 2.1 contrast (≥3.0:1)
    /// against `background`. When neither passes (dead zone), returns accentFgDark.
    /// When both pass, prefers higher contrast. Falls back to `accentFgDark` when
    /// sRGB extraction is unavailable.
    static func accentForeground(on background: Color) -> Color {
        guard let lBg = sRGBLuminance(of: background) else { return accentFgDark }
        let cLight = contrastRatio(lBg, luminanceFgLight)
        let cDark  = contrastRatio(lBg, luminanceFgDark)
        let lightPasses = cLight >= contrastThreshold
        let darkPasses  = cDark  >= contrastThreshold
        if lightPasses != darkPasses { return lightPasses ? accentFgLight : accentFgDark }
        // Neither passes (dead zone): always use dark variant.
        if !lightPasses { return accentFgDark }
        // Both pass: pick whichever has higher contrast.
        return lBg > 0.179 ? accentFgDark : accentFgLight
    }

    /// Whether an over-cover control should sit on a LIGHT (white) surface — true for dark covers. Mirrors
    /// the `accentForeground` light-variant decision (incl. the dead-zone default to dark), so the hero
    /// buttons pick their variant from the COVER, not the device appearance.
    static func prefersLightControl(on background: Color) -> Bool {
        guard let lBg = sRGBLuminance(of: background) else { return false }
        let lightPasses = contrastRatio(lBg, luminanceFgLight) >= contrastThreshold
        let darkPasses  = contrastRatio(lBg, luminanceFgDark)  >= contrastThreshold
        if lightPasses != darkPasses { return lightPasses }
        if !lightPasses { return false }   // dead zone -> dark control
        return lBg <= 0.179                 // both pass -> light control only on a genuinely dark cover
    }

    /// Unified (background, glyph/label) for ALL hero over-cover buttons (chevron/pencil, transport, Play).
    /// Dark cover -> WHITE surface + the cover's `dominantColor` glyph; light/mid/dead-zone -> the deep
    /// orange-red accent surface + white glyph. Single source so every hero button stays consistent.
    static func heroButtonVariant(on dominantColor: Color) -> (background: Color, foreground: Color) {
        if prefersLightControl(on: dominantColor) {
            return (background: .white, foreground: dominantColor)
        }
        return (background: accentForeground(on: dominantColor), foreground: .white)
    }

    // MARK: - WCAG 2.1 luminance

    private static func sRGBLuminance(of color: Color) -> Double? {
        guard let (r, g, b) = sRGBComponents(of: color) else { return nil }
        return 0.2126 * linearize(r) + 0.7152 * linearize(g) + 0.0722 * linearize(b)
    }

    private static func contrastRatio(_ a: Double, _ b: Double) -> Double {
        let lighter = max(a, b)
        let darker  = min(a, b)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static func linearize(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    // MARK: - Platform bridge

    private static func sRGBComponents(of color: Color) -> (Double, Double, Double)? {
        let ui = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        return (Double(r), Double(g), Double(b))
    }
}
