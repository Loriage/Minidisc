import SwiftUI

extension View {
    /// Use white glyphs on this dark surface to maintain contrast over light artwork.
    func minidiscSolidCircleButton(size: CGFloat = 44) -> some View {
        self
            .frame(width: size, height: size)
            .background(Color.black.opacity(0.3), in: Circle())
            .contentShape(Circle())
    }
}
