import SwiftUI

enum PlaylistGradientShape: String, CaseIterable, Codable, Sendable, Identifiable {
    case verticalFade
    case diagonalSheen
    case radialGlow
    case angularSweep
    case mesh

    case prism
    case sunset
    case aurora
    case lagoon
    case bloom
    case ember

    static let selectable: [PlaylistGradientShape] = [.prism, .sunset, .aurora, .lagoon, .bloom, .ember]

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .verticalFade:  return "Fade"
        case .diagonalSheen: return "Sheen"
        case .radialGlow:    return "Glow"
        case .angularSweep:  return "Sweep"
        case .mesh:          return "Mesh"
        case .prism:         return "Prism"
        case .sunset:        return "Sunset"
        case .aurora:        return "Aurora"
        case .lagoon:        return "Lagoon"
        case .bloom:         return "Bloom"
        case .ember:         return "Ember"
        }
    }

    var meshPalette: PlaylistMeshPalette? {
        switch self {
        case .verticalFade, .diagonalSheen, .radialGlow, .angularSweep, .mesh:
            return nil
        case .prism:
            return PlaylistMeshPalette(seed: 0x9E37_79B9, keys: [
                "#FFB25B", "#FF7A5C", "#FF5470", "#FF8FA3", "#7FE7D0", "#5AC8FA", "#6C7BFF",
            ])
        case .sunset:
            return PlaylistMeshPalette(seed: 0x2545_F491, keys: [
                "#FFD26F", "#FFA45B", "#FF6B6B", "#FF5F8D", "#C43E9E", "#8E44AD", "#5B2C8D",
            ])
        case .aurora:
            return PlaylistMeshPalette(seed: 0x1357_1234, keys: [
                "#0F3057", "#16697A", "#1B998B", "#4ECDC4", "#6FFFE9", "#5F27CD", "#8E7DFF",
            ])
        case .lagoon:
            return PlaylistMeshPalette(seed: 0x0BAD_C0DE, keys: [
                "#023E8A", "#0077B6", "#0096C7", "#48CAE4", "#00C2A8", "#90E0EF", "#CDF5E8",
            ])
        case .bloom:
            return PlaylistMeshPalette(seed: 0x5EED_B10E, keys: [
                "#FFD6A5", "#FFC3E1", "#FFA9C6", "#FF8FB1", "#FF5D8F", "#C86FC9", "#E0A8E8",
            ])
        case .ember:
            return PlaylistMeshPalette(seed: 0x00E3_1B12, keys: [
                "#FFD166", "#FFA62B", "#FF7B00", "#FF6B35", "#E63946", "#D62828", "#9D0208",
            ])
        }
    }
}

struct PlaylistMeshPalette: Sendable {
    static let width = 5
    static let height = 5

    let colors: [Color]
    let points: [SIMD2<Float>]
    let representative: Color

    init(seed: UInt64, keys: [String]) {
        let palette = keys.map { Color(hex: $0) }
        self.representative = palette[palette.count / 2]

        var rng = SplitMix64(seed: seed)
        var colors: [Color] = []
        var points: [SIMD2<Float>] = []
        for row in 0..<Self.height {
            for column in 0..<Self.width {
                let x = Float(column) / Float(Self.width - 1)
                let y = Float(row) / Float(Self.height - 1)

                let onVerticalEdge = column == 0 || column == Self.width - 1
                let onHorizontalEdge = row == 0 || row == Self.height - 1
                points.append(SIMD2(
                    onVerticalEdge ? x : x + rng.nextSigned() * Self.wobble,
                    onHorizontalEdge ? y : y + rng.nextSigned() * Self.wobble
                ))

                let ramp = (x + y) / 2 + rng.nextSigned() * Self.colorWobble
                let index = Int(ramp.clamped(to: 0...0.999) * Float(palette.count))
                colors.append(palette[min(index, palette.count - 1)])
            }
        }
        self.colors = colors
        self.points = points
    }

    private static let wobble: Float = 0.085
    private static let colorWobble: Float = 0.22
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func nextSigned() -> Float {
        Float(next() >> 40) / Float(1 << 23) * 2 - 1
    }
}

struct PlaylistMeshGradientView: View {
    let palette: PlaylistMeshPalette
    var points: [SIMD2<Float>]?

    var body: some View {
        GeometryReader { geo in
            MeshGradient(
                width: PlaylistMeshPalette.width,
                height: PlaylistMeshPalette.height,
                points: points ?? palette.points,
                colors: palette.colors
            )
            .blur(radius: min(geo.size.width, geo.size.height) * 0.06, opaque: true)
        }
    }
}

struct PlaylistGradientSpec: Codable, Equatable, Sendable {
    var shape: PlaylistGradientShape
    var red: Double
    var green: Double
    var blue: Double

    var baseColor: Color { Color(red: red, green: green, blue: blue) }

    init(shape: PlaylistGradientShape, baseColor: Color) {
        self.shape = shape
        let source = shape.meshPalette?.representative ?? baseColor
        let rgb = source.rgbComponents ?? (0.30, 0.32, 0.40)
        self.red = rgb.red
        self.green = rgb.green
        self.blue = rgb.blue
    }

    init(shape: PlaylistGradientShape, red: Double, green: Double, blue: Double) {
        self.shape = shape
        self.red = red
        self.green = green
        self.blue = blue
    }

    static func neutral(shape: PlaylistGradientShape = .prism) -> PlaylistGradientSpec {
        PlaylistGradientSpec(shape: shape, baseColor: Color.minidiscAccent)
    }
}

struct PlaylistGradientView: View {
    let spec: PlaylistGradientSpec

    var body: some View {
        if let palette = spec.shape.meshPalette {
            PlaylistMeshGradientView(palette: palette)
        } else {
            form
        }
    }

    @ViewBuilder
    private var form: some View {
        let base = spec.baseColor
        let light = base.adjusted(saturation: -0.04, brightness: 0.18)
        let dark = base.adjusted(saturation: 0.06, brightness: -0.24)

        switch spec.shape {
        case .verticalFade:
            LinearGradient(colors: [light, base, dark], startPoint: .top, endPoint: .bottom)
        case .diagonalSheen:
            LinearGradient(colors: [light, base, dark], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .radialGlow:
            RadialGradient(colors: [light, base, dark], center: .center, startRadius: 0, endRadius: 360)
        case .angularSweep:
            AngularGradient(colors: [base, light, base.adjusted(hue: 0.08), dark, base], center: .center)
        case .mesh:
            meshOrFallback(base: base, light: light, dark: dark)
        case .prism, .sunset, .aurora, .lagoon, .bloom, .ember:
            EmptyView()
        }
    }

    private func meshOrFallback(base: Color, light: Color, dark: Color) -> some View {
        MeshGradient(
            width: 3, height: 3,
            points: [
                [0.0, 0.0], [0.5, 0.0], [1.0, 0.0],
                [0.0, 0.5], [0.5, 0.5], [1.0, 0.5],
                [0.0, 1.0], [0.5, 1.0], [1.0, 1.0],
            ],
            colors: [
                light, base, light,
                base, base.adjusted(hue: 0.05), dark,
                dark, base, dark,
            ]
        )
    }
}

struct AnimatedGradientHeroView: View {
    let spec: PlaylistGradientSpec

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false

    var body: some View {
        Group {
            if let palette = spec.shape.meshPalette {
                presetMesh(palette)
            } else {
                formMesh
            }
        }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
    }

    private var isAnimating: Bool { isVisible && !reduceMotion }

    @ViewBuilder
    private func presetMesh(_ palette: PlaylistMeshPalette) -> some View {
        if isAnimating {
            TimelineView(.animation) { context in
                PlaylistMeshGradientView(
                    palette: palette,
                    points: Self.drifted(palette.points, at: context.date.timeIntervalSinceReferenceDate)
                )
            }
        } else {
            PlaylistMeshGradientView(palette: palette)
        }
    }

    @ViewBuilder
    private var formMesh: some View {
        let base = spec.baseColor
        let light = base.adjusted(saturation: -0.04, brightness: 0.18)
        let dark = base.adjusted(saturation: 0.06, brightness: -0.24)
        let colors = Self.meshColors(spec.shape, base: base, light: light, dark: dark)

        Group {
            if isAnimating {
                TimelineView(.animation) { context in
                    MeshGradient(width: 3, height: 3,
                                 points: Self.points(at: context.date.timeIntervalSinceReferenceDate),
                                 colors: colors)
                }
            } else {
                MeshGradient(width: 3, height: 3, points: Self.restPoints, colors: colors)
            }
        }
        .scaleEffect(1.25)
        .clipped()
    }

    private static func drifted(_ points: [SIMD2<Float>], at t: TimeInterval) -> [SIMD2<Float>] {
        let width = PlaylistMeshPalette.width
        let height = PlaylistMeshPalette.height
        return points.enumerated().map { index, point in
            let row = index / width
            let column = index % width
            guard row > 0, row < height - 1, column > 0, column < width - 1 else { return point }
            let phase = Double(index) * 1.7
            return SIMD2(
                point.x + Float(sin(t * 0.42 + phase) * 0.045),
                point.y + Float(sin(t * 0.35 + phase * 1.3) * 0.045)
            )
        }
    }

    private static let nodes: [(bx: Double, by: Double, ax: Double, ay: Double, wx: Double, wy: Double, px: Double, py: Double)] = [
        (-0.05, -0.05, 0.10, 0.10, 1.10, 1.43, 0.0, 1.9),
        ( 0.50, -0.06, 0.13, 0.09, 1.27, 1.02, 2.3, 0.5),
        ( 1.05, -0.05, 0.10, 0.10, 0.97, 1.51, 3.6, 2.8),
        (-0.06,  0.50, 0.09, 0.13, 1.33, 1.13, 1.3, 4.2),
        ( 0.50,  0.50, 0.16, 0.16, 1.04, 1.39, 0.7, 3.3),
        ( 1.06,  0.50, 0.09, 0.13, 1.49, 0.99, 4.8, 1.2),
        (-0.05,  1.05, 0.10, 0.10, 1.06, 1.21, 5.3, 0.3),
        ( 0.50,  1.06, 0.13, 0.09, 1.18, 1.46, 2.9, 5.6),
        ( 1.05,  1.05, 0.10, 0.10, 1.41, 0.95, 2.0, 4.0),
    ]

    private static func points(at t: TimeInterval) -> [SIMD2<Float>] {
        nodes.map { n in
            SIMD2<Float>(Float(n.bx + n.ax * sin(t * n.wx + n.px)),
                         Float(n.by + n.ay * sin(t * n.wy + n.py)))
        }
    }

    private static var restPoints: [SIMD2<Float>] {
        nodes.map { SIMD2<Float>(Float($0.bx), Float($0.by)) }
    }

    private static func meshColors(_ shape: PlaylistGradientShape, base: Color, light: Color, dark: Color) -> [Color] {
        if let palette = shape.meshPalette { return palette.colors }
        let hue = base.adjusted(hue: 0.07)
        switch shape {
        case .verticalFade:
            return [light, light, light, base, base, base, dark, dark, dark]
        case .diagonalSheen:
            return [light, light, base, light, base, dark, base, dark, dark]
        case .radialGlow:
            return [dark, base, dark, base, light, base, dark, base, dark]
        case .angularSweep:
            return [base, light, hue, dark, base, light, hue, dark, base]
        case .mesh:
            return [light, base, light, base, hue, dark, dark, base, dark]
        case .prism, .sunset, .aurora, .lagoon, .bloom, .ember:
            return []
        }
    }
}
