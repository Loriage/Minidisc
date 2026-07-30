import SwiftUI

/// Renders a `PlaylistGradientSpec` to a square JPEG to become a real playlist cover. Mirrors the proven
/// `WrappedCoverRenderer` path: `ImageRenderer` (cross-platform) + a platform JPEG-encode bridge (the only
/// `#if os`). The title is baked in when provided, so the uploaded cover is what the picker previewed —
/// no client re-composes the text over a live gradient.
@MainActor
enum PlaylistGradientRenderer {
    static func jpegData(
        for spec: PlaylistGradientSpec,
        title: String?,
        side: CGFloat = 1024,
        compression: Double = 0.85
    ) -> Data? {
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let view = ZStack {
            PlaylistGradientView(spec: spec)
            if !trimmedTitle.isEmpty {
                titleOverlay(trimmedTitle, side: side)
            }
        }
        .frame(width: side, height: side)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1.0

        return renderer.uiImage?.jpegData(compressionQuality: compression)
    }

    /// Same ratios as the picker preview, so the raster matches what was chosen at any size. The block starts
    /// at 30% of the side: on the playlist detail hero the cover runs under the toolbar, and three lines of
    /// title must clear it.
    private static func titleOverlay(_ title: String, side: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: side * 0.15, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(3)
                .minimumScaleFactor(0.6)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, side * 0.09)
        .padding(.top, side * 0.30)
        .padding(.bottom, side * 0.09)
    }
}
