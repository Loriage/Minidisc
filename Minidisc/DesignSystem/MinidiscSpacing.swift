import SwiftUI

// MARK: - Spacing scale (4pt grid)

nonisolated enum MinidiscSpacing {
    static let xs: CGFloat    = 4
    static let s: CGFloat     = 8
    static let m: CGFloat     = 12
    static let l: CGFloat     = 16   // default horizontal screen padding
    static let xl: CGFloat    = 20
    static let xxl: CGFloat   = 24   // between sections
    static let xxxl: CGFloat  = 32
    static let xxxxl: CGFloat = 48

    /// Vertical gap between page sections (shelves, track list, discography groups). Use it for every
    /// section on scrolling pages so headers never crowd the content above them.
    static let section: CGFloat = 32

    /// Right inset for track rows ending in a duration. Wider than the leading inset: the track number on
    /// the left is centred in its column, so this balances the visible gaps on both edges.
    static let trackRowTrailing: CGFloat = 32

    /// Bottom scroll margin reserved for the iOS tabViewBottomAccessory mini player,
    /// which floats over tab content without extending the safe area.
    static let miniPlayerBottomMargin: CGFloat = 80
}

// MARK: - Corner radius scale

enum MinidiscCornerRadius {
    static let xs: CGFloat       = 4
    static let s: CGFloat        = 6
    static let standard: CGFloat = 8    // all cover arts, most cards
    static let large: CGFloat     = 12   // full-player cover art, sheets
    static let hero: CGFloat      = 20   // Wrapped stat hero, year card
    static let pill: CGFloat      = 999  // capsule buttons
}

// MARK: - Control sizes

/// Tap-target diameters for circular controls. Never go below `regular` (44pt HIG minimum) for primary actions.
enum MinidiscControlSize {
    static let compact: CGFloat   = 36   // inline accessories (row hearts)
    static let regular: CGFloat   = 44   // secondary circle buttons, toolbars
    static let large: CGFloat     = 52   // album / artist / playlist action rows (all buttons equal)
}

// MARK: - Shadow presets

enum MinidiscShadow {
    static let coverRadius: CGFloat  = 8
    static let coverY: CGFloat       = 4
    static let coverOpacity: Double  = 0.15
}

// MARK: - View modifier: content width

struct ContentWidthModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        content
    }
}

extension View {
    func minidiscContentWidth() -> some View {
        modifier(ContentWidthModifier())
    }

    /// Hides the iOS 26 scroll-edge effect (the soft blur the system fades under top bars). Used on the
    /// immersive detail scroll views, where the cover scrolls under a transparent nav bar and the blur would
    /// otherwise flicker in/out behind it.
    func minidiscHideTopScrollEdgeEffect() -> some View {
        scrollEdgeEffectHidden(true, for: .top)
    }
}

// MARK: - View modifier: cover art style

struct MinidiscCoverModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay {
                if colorScheme == .dark {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(Color.minidiscCoverBorder, lineWidth: 1)
                }
            }
    }
}

extension View {
    func minidiscCoverStyle(cornerRadius: CGFloat = MinidiscCornerRadius.standard) -> some View {
        modifier(MinidiscCoverModifier(cornerRadius: cornerRadius))
    }
}
