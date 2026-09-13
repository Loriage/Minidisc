import SwiftUI

/// Five fixed illustrations, available offline and unaffected by playlist contents.
/// Rasterized once per mood so scrolling never redraws a mesh gradient per tile.
struct MoodArtwork: View {
    let mood: Mood
    @State private var artwork: UIImage?

    var body: some View {
        ZStack {
            mood.gradientSpec.baseColor
            if let artwork {
                Image(uiImage: artwork)
                    .resizable()
                    .scaledToFill()
            }
        }
        .clipped()
        .accessibilityHidden(true)
        .task(id: mood) { artwork = MoodArtworkRenderer.image(for: mood) }
    }
}

@MainActor
private enum MoodArtworkRenderer {
    private static var images: [Mood: UIImage] = [:]

    static func image(for mood: Mood) -> UIImage? {
        if let image = images[mood] { return image }
        let side: CGFloat = 420
        let renderer = ImageRenderer(content:
            ZStack {
                PlaylistGradientView(spec: mood.gradientSpec)
                LinearGradient(colors: [.black.opacity(0.04), .black.opacity(0.30)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: mood.symbolName)
                    .font(.system(size: side * 0.30, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.18), radius: side * 0.035, y: side * 0.015)
            }
            .frame(width: side, height: side)
        )
        renderer.scale = 1
        let image = renderer.uiImage
        images[mood] = image
        return image
    }
}
