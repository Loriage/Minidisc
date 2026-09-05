import SwiftUI

/// Keeps the cover itself intact, then carries its lower edge into a readable page background.
struct PlaylistArtworkHeader: View {
    let coverArtId: String
    let initialImage: PlatformImage?
    let backgroundColor: Color

    var body: some View {
        GeometryReader { geometry in
            let stretch = max(0, geometry.frame(in: .global).minY)
            CoverArtView(id: coverArtId, size: 1000, initialImage: initialImage)
                .frame(width: geometry.size.width, height: geometry.size.height + stretch)
                .clipped()
                .overlay {
                    LinearGradient(
                        stops: [
                            .init(color: backgroundColor.opacity(0), location: 0.45),
                            .init(color: backgroundColor.opacity(0.18), location: 0.62),
                            .init(color: backgroundColor.opacity(0.72), location: 0.82),
                            .init(color: backgroundColor, location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .offset(y: -stretch)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playlist cover")
        .accessibilityIdentifier("playlist.detail.artwork")
    }
}

/// Darkens the sampled colour without changing its hue or washing it out to grey.
enum PlaylistArtworkPalette {
    static func background(for coverColor: Color) -> Color {
        guard coverColor != .clear, let rgb = coverColor.rgbComponents else {
            return Color(white: 0.06)
        }
        let peak = max(rgb.red, rgb.green, rgb.blue)
        let scale = peak > 0.22 ? 0.22 / peak : 1
        return Color(red: rgb.red * scale, green: rgb.green * scale, blue: rgb.blue * scale)
    }
}
