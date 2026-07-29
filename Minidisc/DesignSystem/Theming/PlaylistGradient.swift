import SwiftUI

/// A generated playlist cover, in two families.
///
/// **Mesh presets** (`prism`…`ember`) carry their own multi-colour palette and are the only choices the cover
/// picker offers — see `selectable`.
///
/// **Legacy forms** (`verticalFade`…`mesh`) are a geometry only, coloured from the playlist's first track.
/// They are no longer offered, and stay for the two places that still render them: the mood playlists, which
/// use one form each so the five read apart at thumbnail size, and any cover picked before the presets landed.
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

    /// What the cover picker offers, in order.
    static let selectable: [PlaylistGradientShape] = [.prism, .sunset, .aurora, .lagoon, .bloom, .ember]

    var id: String { rawValue }

    /// The picker's caption. Only `selectable` shapes reach a screen; the legacy forms keep a name for
    /// debugging and never get looked up for translation.
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

    /// The fixed palette for a mesh preset, `nil` for a legacy form.
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

/// The fixed 5×5 mesh behind a preset. Each cell walks the preset's key colours along the diagonal with a
/// seeded wobble that pulls them out of their band into blobs; the grid points get the same treatment. Shape
/// and colour zones therefore both come from the one seed, so every render of a preset is identical.
///
/// Corners stay pinned and edge points only slide ALONG their own edge, so the mesh always fills its frame.
struct PlaylistMeshPalette: Sendable {
    static let width = 5
    static let height = 5

    let colors: [Color]
    let points: [SIMD2<Float>]
    /// Stands in for the preset outside the mesh — the frozen spec's base colour, so the playlist screen
    /// still has something to theme its background with.
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

    /// Point offset in grid units. Cells sit 0.25 apart, so this never lets two points cross — a crossed
    /// pair folds its patch over its neighbour and creases the mesh.
    private static let wobble: Float = 0.085
    /// How far a cell may reach up or down the key list.
    private static let colorWobble: Float = 0.22
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

/// Deterministic, so a preset's shape comes from its seed rather than from whatever this launch's
/// `Float.random` gives.
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

    /// A value in -1...1.
    mutating func nextSigned() -> Float {
        Float(next() >> 40) / Float(1 << 23) * 2 - 1
    }
}

/// One preset's mesh, blurred to melt the crisp seams `MeshGradient` leaves where two patches meet. The
/// radius is a FRACTION of the rendered side, so the 60pt swatch, the carousel card, and the 1024pt cover
/// JPEG all get the same look; `opaque` keeps the blur from eating the edges into transparency.
struct PlaylistMeshGradientView: View {
    let palette: PlaylistMeshPalette
    /// Drifted positions when animating; the palette's resting grid otherwise.
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

/// A frozen gradient-cover spec: the chosen form + the resolved base color (the first track's dominant color
/// at creation time). FROZEN — the base color is stored, never re-derived live, so the cover does not drift
/// if the first track later changes. Codable for the SwiftData store; the gradient is rendered from this.
struct PlaylistGradientSpec: Codable, Equatable, Sendable {
    var shape: PlaylistGradientShape
    var red: Double
    var green: Double
    var blue: Double

    var baseColor: Color { Color(red: red, green: green, blue: blue) }

    /// A mesh preset overrides the passed colour with its own: its palette is fixed, so the stored base is
    /// only ever the colour that represents it.
    init(shape: PlaylistGradientShape, baseColor: Color) {
        self.shape = shape
        let source = shape.meshPalette?.representative ?? baseColor
        let rgb = source.rgbComponents ?? (0.30, 0.32, 0.40)
        self.red = rgb.red
        self.green = rgb.green
        self.blue = rgb.blue
    }

    /// Direct reconstruction from stored components (no Color round-trip) — used by the persistence store.
    init(shape: PlaylistGradientShape, red: Double, green: Double, blue: Double) {
        self.shape = shape
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Default/example base for a playlist with no derived color yet (empty playlist) AND the picker's example
    /// swatches — the Minidisc brand accent (orange-red), so the default reads vibrant + on-brand. A preset
    /// ignores it and uses its own palette. Marked elsewhere as a *system* default (not a user pick), so a
    /// real choice never gets overwritten; the derived-from-track path is separate and unaffected.
    static func neutral(shape: PlaylistGradientShape = .prism) -> PlaylistGradientSpec {
        PlaylistGradientSpec(shape: shape, baseColor: Color.minidiscAccent)
    }
}

/// Renders a `PlaylistGradientSpec` as a SwiftUI view — used for the picker preview and (off-screen) for the
/// JPEG render that becomes the real cover. Switches on the form; each derives its stops from the one base
/// color via `Color.adjusted`. Cross-platform; the mesh form falls back to a linear gradient pre-iOS 18.
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
            EmptyView()   // handled by `body` from the fixed palette
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

/// The ANIMATED crisp hero cover for a gradient playlist — a `MeshGradient` (iOS 18+, always taken on the
/// iOS-26 min target) whose control points drift slowly for a subtle living motion (Apple-Music feel).
/// SEPARATE from `PlaylistGradientView`, which stays static so the off-screen JPEG snapshot is deterministic.
/// The 6 forms map to 6 nine-color mesh arrangements derived from the spec's base/light/dark shades.
/// Foreground only (no blur) so the animation is cheap; the background/melt stays static (rasterized once).
/// Honors Reduce Motion (static then) and pauses off-screen (the cover row stops rendering; `onDisappear`
/// resets the drift).
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

    /// A preset drifts its own grid. Only the interior points move, so the mesh keeps filling the frame and
    /// needs none of the overfill the forms below rely on.
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
        // Overfill + clip: the mesh renders ~1.25x the frame, so the outer control points (biased outward) can
        // roam fully without ever exposing a frame edge — that's what unlocks the motion vs pinned corners. The
        // center roams free (bounded so colors never collapse into hard bands). Foreground only -> cheap.
        .scaleEffect(1.25)
        .clipped()
    }

    /// Drifts a preset grid's interior points, leaving every edge point where the palette put it.
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

    /// Per node: a base biased OUTWARD for the outer points (pushed into the overfill margin so their inward
    /// swing never crosses the frame edge) + independent per-axis amplitude / angular frequency / phase ->
    /// organic Lissajous drift (no uniform pulse). Periods ~4-6s; the center has the largest, bounded amplitude.
    private static let nodes: [(bx: Double, by: Double, ax: Double, ay: Double, wx: Double, wy: Double, px: Double, py: Double)] = [
        (-0.05, -0.05, 0.10, 0.10, 1.10, 1.43, 0.0, 1.9),  // 0 TL corner
        ( 0.50, -0.06, 0.13, 0.09, 1.27, 1.02, 2.3, 0.5),  // 1 T edge
        ( 1.05, -0.05, 0.10, 0.10, 0.97, 1.51, 3.6, 2.8),  // 2 TR corner
        (-0.06,  0.50, 0.09, 0.13, 1.33, 1.13, 1.3, 4.2),  // 3 L edge
        ( 0.50,  0.50, 0.16, 0.16, 1.04, 1.39, 0.7, 3.3),  // 4 center
        ( 1.06,  0.50, 0.09, 0.13, 1.49, 0.99, 4.8, 1.2),  // 5 R edge
        (-0.05,  1.05, 0.10, 0.10, 1.06, 1.21, 5.3, 0.3),  // 6 BL corner
        ( 0.50,  1.06, 0.13, 0.09, 1.18, 1.46, 2.9, 5.6),  // 7 B edge
        ( 1.05,  1.05, 0.10, 0.10, 1.41, 0.95, 2.0, 4.0),  // 8 BR corner
    ]

    private static func points(at t: TimeInterval) -> [SIMD2<Float>] {
        nodes.map { n in
            SIMD2<Float>(Float(n.bx + n.ax * sin(t * n.wx + n.px)),
                         Float(n.by + n.ay * sin(t * n.wy + n.py)))
        }
    }

    /// Rest position (Reduce Motion / off-screen): the un-drifted biased grid.
    private static var restPoints: [SIMD2<Float>] {
        nodes.map { SIMD2<Float>(Float($0.bx), Float($0.by)) }
    }

    /// Per-form 9-color arrangement echoing the static `PlaylistGradientView` look of each shape. A mesh
    /// preset brings its own palette, so it drifts like the forms do without deriving anything.
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
            return []   // unreachable: the palette short-circuits above
        }
    }
}
