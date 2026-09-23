import SwiftUI

public enum MinidiscColors {
    
    public static let accent = Color("MinidiscAccent")

    public static let accentBackground = Color("MinidiscAccentBackground")

    public static let accentForeground = Color("MinidiscAccentForeground")

    public static let backgroundPrimary = Color("MinidiscBackgroundPrimary")

    public static let backgroundSecondary = Color("MinidiscBackgroundSecondary")

    public static let backgroundTertiary = Color("MinidiscBackgroundTertiary")

    public static let textPrimary = Color("MinidiscTextPrimary")

    public static let textSecondary = Color("MinidiscTextSecondary")

    public static let textTertiary = Color("MinidiscTextTertiary")

    public static let separator = Color("MinidiscSeparator")

    public static let border = Color("MinidiscBorder")
    
    // MARK: — Accent Ramp (raw orange-red stops, light-mode only — gradients, artwork tints, brand chips).
    public enum AccentRamp {
        public static let v50  = Color(hex: "#FFF1EC")
        public static let v100 = Color(hex: "#FFDACE")
        public static let v200 = Color(hex: "#FFB6A0")
        public static let v300 = Color(hex: "#FF8E6E")
        public static let v400 = Color(hex: "#FF6242")
        public static let v500 = Color(hex: "#D63A0F") // brand chip base — keeps white legible (~4.7:1)
        public static let v600 = Color(hex: "#B72F0A")
        public static let v700 = Color(hex: "#8F2408")
        public static let v800 = Color(hex: "#661905")
        public static let v900 = Color(hex: "#3D0E02")
    }
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8)  & 0xFF) / 255
        let b = Double(int         & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

// AccentColor mirrors MinidiscAccent. Apply branded tints locally, not at WindowGroup,
// so secondary actions and alerts retain their contextual appearance.
