import SwiftUI

extension View {
    /// Solid dark circular button for the detail-header action row (shuffle / download). A semi-opaque
    /// dark disc reads consistently over any themed melt background — unlike Liquid Glass, which washes
    /// out on light covers. Pair the glyph with `.foregroundStyle(.white)`.
    func minidiscSolidCircleButton(size: CGFloat = 44) -> some View {
        self
            .frame(width: size, height: size)
            .background(Color.black.opacity(0.3), in: Circle())
    }

    /// Over-cover HERO round button: TRANSPARENT — no surface/fill. Just the tap area + a soft shadow so the
    /// glyph stays legible on a busy cover without a backing (the Apple-Music trick). The caller colors the
    /// glyph for direct contrast on the cover (the over-cover title color). Pair with `.buttonStyle(.plain)`
    /// to drop the native iOS 26 toolbar glass.
    func minidiscHeroButton(size: CGFloat = 44) -> some View {
        self
            .frame(width: size, height: size)
            .contentShape(Circle())
    }
}
