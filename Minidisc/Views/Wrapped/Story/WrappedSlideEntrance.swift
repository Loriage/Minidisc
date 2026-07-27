import SwiftUI

/// Entrance animation for Wrapped story slide content.
/// Drifts upward on appear; respects Reduce Motion (instant appear, no drift).
struct WrappedSlideEntrance: ViewModifier {
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .offset(y: appeared || reduceMotion ? 0 : 24)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.spring(response: 0.55, dampingFraction: 0.82).delay(0.1)) {
                    appeared = true
                }
            }
    }
}

extension View {
    func wrappedSlideEntrance() -> some View {
        modifier(WrappedSlideEntrance())
    }
}
