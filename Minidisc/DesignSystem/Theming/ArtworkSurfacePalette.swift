import SwiftUI

/// The shared dark, cover-tinted surface behind artwork-led screens (album, artist, player).
/// These screens are always dark, whatever the system appearance: the cover's hue is kept, its luminance
/// capped so white text stays at least 7:1 and 70% white secondary text above 4.5:1.
enum ArtworkSurfacePalette {
    /// Luminance cap for the top of the surface. White on 0.1 is 7:1.
    static let maxTintLuminance = 0.1
    /// The bottom of the surface is the tint at this fraction, close to black.
    static let baseDepth = 0.32
    /// Used before the cover colour is known, and for monochrome or missing artwork.
    static let neutral = Color(white: 0.09)

    /// The tinted top colour for a cover's dominant colour.
    static func tint(from coverColor: Color) -> Color {
        guard coverColor != .clear, let rgb = coverColor.rgbComponents else { return neutral }

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
            .getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        // Near-grey covers stay neutral; chromatic ones get a little more colour so the tint reads after darkening.
        let isChromatic = saturation >= 0.08
        let adjustedSaturation = isChromatic ? min(saturation * 1.3, 0.85) : saturation
        var color = UIColor(hue: hue, saturation: adjustedSaturation, brightness: max(brightness, 0.2), alpha: 1)

        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &alpha)
        var red = Double(r), green = Double(g), blue = Double(b)
        while PlayerBackgroundPalette.luminance(red: red, green: green, blue: blue) > maxTintLuminance {
            red *= 0.95
            green *= 0.95
            blue *= 0.95
        }
        color = UIColor(red: red, green: green, blue: blue, alpha: 1)
        return Color(uiColor: color)
    }

    /// The near-black bottom colour that pairs with `tint(from:)`.
    static func base(from tint: Color) -> Color {
        guard let rgb = tint.rgbComponents else { return .black }
        return Color(red: rgb.red * baseDepth, green: rgb.green * baseDepth, blue: rgb.blue * baseDepth)
    }
}

/// The page background for artwork-led screens: tint at the top fading to the base.
struct ArtworkSurfaceBackground: View {
    let tint: Color

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: tint, location: 0),
                .init(color: tint, location: 0.15),
                .init(color: ArtworkSurfacePalette.base(from: tint), location: 0.75)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}
