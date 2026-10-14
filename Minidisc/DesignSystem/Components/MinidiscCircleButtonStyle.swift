import SwiftUI

/// The round, softly filled button used across artwork-led screens: the player's heart and menu, the
/// album and artist action rows, and the player toolbar. Use on dark surfaces; the fill and glyph follow
/// the foreground style so they read on any tint.
struct MinidiscCircleButtonStyle: ButtonStyle {
    var diameter: CGFloat = MinidiscControlSize.regular
    /// The play button in an action row: a stronger fill at the same size as its neighbours.
    var isProminent = false
    /// Highlights a toggled state (e.g. the queue or lyrics surface is showing).
    var isActive = false

    func makeBody(configuration: Configuration) -> some View {
        CircleButtonBody(
            configuration: configuration,
            diameter: diameter,
            isProminent: isProminent,
            isActive: isActive
        )
    }

    private struct CircleButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let diameter: CGFloat
        let isProminent: Bool
        let isActive: Bool

        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

        private var fillOpacity: Double {
            if isActive { return 0.9 }
            return isProminent ? 0.24 : 0.16
        }

        var body: some View {
            // Grow with Dynamic Type, but cap so a row of four still fits on a compact phone.
            let size = min(diameter * scale, diameter * 1.35)
            configuration.label
                .labelStyle(.iconOnly)
                .font(.body.weight(.semibold))
                .foregroundStyle(isActive ? AnyShapeStyle(Color.black) : AnyShapeStyle(.primary))
                .frame(width: size, height: size)
                .background(Circle().fill(.primary.opacity(fillOpacity)))
                .contentShape(Circle())
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.92 : 1)
                .opacity(isEnabled ? 1 : 0.4)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
        }
    }
}

extension ButtonStyle where Self == MinidiscCircleButtonStyle {
    static func minidiscCircle(
        diameter: CGFloat = MinidiscControlSize.regular,
        isProminent: Bool = false,
        isActive: Bool = false
    ) -> MinidiscCircleButtonStyle {
        MinidiscCircleButtonStyle(diameter: diameter, isProminent: isProminent, isActive: isActive)
    }
}

#Preview {
    HStack(spacing: MinidiscSpacing.l) {
        Button("Favorite", systemImage: "heart") {}
            .buttonStyle(.minidiscCircle(diameter: MinidiscControlSize.large))
        Button("Play", systemImage: "play.fill") {}
            .buttonStyle(.minidiscCircle(diameter: MinidiscControlSize.large, isProminent: true))
        Button("Shuffle", systemImage: "shuffle") {}
            .buttonStyle(.minidiscCircle(diameter: MinidiscControlSize.large))
        Button("Queue", systemImage: "list.bullet") {}
            .buttonStyle(.minidiscCircle(isActive: true))
    }
    .padding()
    .background(ArtworkSurfaceBackground(tint: ArtworkSurfacePalette.tint(from: .orange)))
    .environment(\.colorScheme, .dark)
}
