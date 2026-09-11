import SwiftUI

/// Keeps the artwork's hue distribution while supporting the player's white secondary labels.
enum PlayerBackgroundPalette {
    static func colors(from samples: [Color]) -> [Color] {
        samples.enumerated().map { index, sample in
            guard let rgb = sample.rgbComponents else { return .black }
            let depth = 1 - 0.12 * Double(index) / Double(max(samples.count - 1, 1))
            var r = rgb.red * depth
            var g = rgb.green * depth
            var b = rgb.blue * depth
            // Cap relative luminance, including at bright bands. Convex interpolation between
            // these sRGB stops stays under the cap, so a light stripe cannot cross the controls.
            while luminance(red: r, green: g, blue: b) > 0.09 {
                r *= 0.96
                g *= 0.96
                b *= 0.96
            }
            return Color(red: r, green: g, blue: b)
        }
    }

    static func luminance(red: Double, green: Double, blue: Double) -> Double {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}
