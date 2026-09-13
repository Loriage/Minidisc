import SwiftUI

/// Place first in a scroll view with a bodyColor background, transparent navigation bar
/// and ignored top safe area. The cover stretches during overscroll.
struct ImmersiveCoverHero<Content: View>: View {
    let coverArtId: String?
    let coverImage: PlatformImage?
    let theme: PlaylistTheme
    let heroHeight: CGFloat
    var coverRefreshID: AnyHashable = 0
    /// When true the cover keeps its square ratio and the content sits BELOW it (album/playlist covers shown in
    /// full); when false (default) the content floats over the full-bleed cover (artist photos).
    var contentBelow: Bool = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        if contentBelow {
            VStack(spacing: 0) {
                coverHero
                content()
                    .padding(.top, MinidiscSpacing.m)
                    .padding(.bottom, MinidiscSpacing.xl)
            }
            .frame(maxWidth: .infinity)
        } else {
            ZStack(alignment: .bottom) {
                coverHero
                content()
                    .padding(.bottom, MinidiscSpacing.l)
            }
            .frame(height: heroHeight)
            .frame(maxWidth: .infinity)
        }
    }

    private var coverHero: some View {
        GeometryReader { geo in
            // Stretchy header: on over-scroll at the top, grow the cover UPWARD to fill the bounce instead of
            // revealing the solid page color behind it.
            let stretch = max(0, geo.frame(in: .global).minY)
            PlaylistThemedBackground(
                coverArtId: coverArtId,
                coverImage: coverImage,
                theme: theme,
                heroHeight: heroHeight,
                lightMelt: contentBelow
            )
            .frame(width: geo.size.width, height: heroHeight + stretch)
            .offset(y: -stretch)
            .id(coverRefreshID)
        }
        .frame(height: heroHeight)
    }
}
