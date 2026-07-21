// Minidisc — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

// MARK: - Minidisc Design Tokens
// Brand accent: Orange-Red (#E8420E light / #FF6242 dark).
// All colors are adaptive (light/dark) via Asset Catalog Color Sets.
// Asset Catalog entries must be created alongside this file (see spec below).

public enum MinidiscColors {
    
    // MARK: — Accent
    /// Primary brand color. CTA, active icons, progress bars, play button.
    /// Light: #E8420E — Dark: #FF6242 (slightly lighter for contrast on dark bg)
    public static let accent = Color("MinidiscAccent")

    /// Tinted background for badges, pills, active states.
    /// Light: #FFE9E2 — Dark: #38221E
    public static let accentBackground = Color("MinidiscAccentBackground")

    /// Text/icon color on top of accentBackground.
    /// Light: #C4330F — Dark: #FF8C6E
    public static let accentForeground = Color("MinidiscAccentForeground")

    // MARK: — Backgrounds
    /// App-level background. Warm-neutral near-white / near-black.
    public static let backgroundPrimary = Color("MinidiscBackgroundPrimary")

    /// Cards, list rows, bottom sheets, grouped table backgrounds.
    public static let backgroundSecondary = Color("MinidiscBackgroundSecondary")

    /// Elevated content: modals, popovers, context menus.
    public static let backgroundTertiary = Color("MinidiscBackgroundTertiary")

    // MARK: — Text
    /// Primary content: titles, song names, main body text.
    public static let textPrimary = Color("MinidiscTextPrimary")

    /// Supporting content: artist names, subtitles, descriptions.
    public static let textSecondary = Color("MinidiscTextSecondary")

    /// De-emphasized content: durations, placeholders, hints, timestamps.
    public static let textTertiary = Color("MinidiscTextTertiary")

    // MARK: — Structure
    /// List separators, dividers.
    /// Accent orange-red @ 12% (light) / 15% (dark) opacity.
    public static let separator = Color("MinidiscSeparator")

    /// Card borders, input outlines.
    /// Accent orange-red @ 18% (light) / 22% (dark) opacity.
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

// MARK: - Color(hex:) helper
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

/*
 ┌─────────────────────────────────────────────────────────────────────────┐
 │  ASSET CATALOG SPEC — Assets.xcassets (orange-red brand)                │
 │  One Color Set per token. Appearances: "Any, Dark".                     │
 ├──────────────────────────────────┬──────────────────┬───────────────────┤
 │  Color Set Name                  │  Light (Any)     │  Dark             │
 ├──────────────────────────────────┼──────────────────┼───────────────────┤
 │  MinidiscAccent                  │  #E8420E         │  #FF6242          │
 │  MinidiscAccentBackground        │  #FFE9E2         │  #38221E          │
 │  MinidiscAccentForeground        │  #C4330F         │  #FF8C6E          │
 │  MinidiscAccentSecondary         │  #FF8560         │  #FFA588          │
 │  MinidiscBackgroundPrimary       │  #FBFAF9         │  #0F0D0C          │
 │  MinidiscBackgroundSecondary     │  #F5F3F1         │  #1A1614          │
 │  MinidiscBackgroundTertiary      │  #FFFFFF         │  #231D1A          │
 │  MinidiscTextPrimary             │  #1A1614         │  #F5F1EF          │
 │  MinidiscTextSecondary           │  #706B67         │  #A8A09B          │
 │  MinidiscTextTertiary            │  #9C948F         │  #6E6560          │
 │  MinidiscSeparator               │  #E8420E @ 12%   │  #FF6242 @ 15%    │
 │  MinidiscBorder                  │  #E8420E @ 18%   │  #FF6242 @ 22%    │
 └──────────────────────────────────┴──────────────────┴───────────────────┘

 NOTE — The "AccentColor" set mirrors MinidiscAccent so system components
 (toggles, sliders, links) inherit the brand color, and the app applies
 `.tint(MinidiscColors.accent)` at the WindowGroup root.
 */
