import SwiftUI

/// Blends cover artwork into the body color. ImmersiveCoverHero handles overscroll stretching.
struct PlaylistThemedBackground: View {
    let coverArtId: String?
    let coverImage: PlatformImage?
    let theme: PlaylistTheme
    var heroHeight: CGFloat = 460
    /// Fade ONLY the bottom edge (square covers shown in full with content sitting below) instead of the lower
    /// ~half (full-bleed covers with content floating over them).
    var lightMelt: Bool = false

    private var bodyColor: Color { theme.isThemed ? theme.dominantColor : systemBackground }

    var body: some View {
        ZStack(alignment: .top) {
            bodyColor

            if theme.isThemed, let coverArtId {
                ZStack(alignment: .top) {
                    CoverArtView(id: coverArtId, size: 1000, initialImage: coverImage)
                    .frame(maxWidth: .infinity)
                    .frame(height: heroHeight)
                    .clipped()

                    blurredMelt(coverArtId: coverArtId)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
    }

    @ViewBuilder
    private func blurredMelt(coverArtId: String) -> some View {
        ZStack {
            CoverArtView(id: coverArtId, size: 600, initialImage: coverImage)
            .frame(maxWidth: .infinity)
            .frame(height: heroHeight)
            .clipped()
            .blur(radius: 16)

            // Reach the body color before the track list to avoid a pale band behind the controls.
            LinearGradient(
                stops: [
                    .init(color: .clear, location: lightMelt ? 0.82 : 0.30),
                    .init(color: bodyColor, location: lightMelt ? 1.0 : 0.80),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: heroHeight)
        }
        .frame(height: heroHeight)
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: lightMelt ? 0.84 : 0.32),
                    .init(color: .black, location: lightMelt ? 1.0 : 0.85),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .drawingGroup()
    }

    private var systemBackground: Color {
        Color(UIColor.systemBackground)
    }
}
