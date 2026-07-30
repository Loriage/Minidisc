import SwiftUI

extension View {
    /// Solid dark circular button for the detail-header action row (shuffle / download). A semi-opaque
    /// dark disc reads consistently over any themed melt background — unlike Liquid Glass, which washes
    /// out on light covers. Pair the glyph with `.foregroundStyle(.white)`.
    func minidiscSolidCircleButton(size: CGFloat = 44) -> some View {
        self
            .frame(width: size, height: size)
            .background(Color.black.opacity(0.3), in: Circle())
            .contentShape(Circle())
    }
}
