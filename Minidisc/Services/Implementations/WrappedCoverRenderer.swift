// Minidisc — Music client for Subsonic/OpenSubsonic servers
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

@MainActor
enum WrappedCoverRenderer {
    static func generateCoverData(year: Int) -> Data? {
        let view = WrappedCoverImage(year: year)
            .frame(width: 600, height: 600)
            .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2.0

        guard let uiImage = renderer.uiImage else { return nil }
        return uiImage.jpegData(compressionQuality: 0.85)
    }
}

// MARK: - WrappedCoverImage

private struct WrappedCoverImage: View {
    let year: Int

    private var palette: [Color] { WrappedYearPalette.colors(for: year) }

    // Diagonal sweep matching MeshGradientBackground.distributedColors:
    // c0 top-left → c1 center → c2 bottom-right
    private var distributedColors: [Color] {
        let c0 = palette[0], c1 = palette[1], c2 = palette[2]
        return [c0, c0, c1,
                c0, c1, c1,
                c1, c2, c2]
    }

    var body: some View {
        ZStack {
            background
            overlay
        }
    }

    private var background: some View {
        MeshGradient(
            width: 3, height: 3,
            points: [
                [0.0, 0.0], [0.5, 0.0], [1.0, 0.0],
                [0.0, 0.5], [0.5, 0.5], [1.0, 0.5],
                [0.0, 1.0], [0.5, 1.0], [1.0, 1.0]
            ],
            colors: distributedColors
        )
    }

    private var overlay: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Minidisc Wrapped")
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Spacer()
            Text(String(year))
                .font(.system(size: 200, weight: .black, design: .rounded))
                .kerning(-4)
                .foregroundStyle(.white.opacity(0.95))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(40)
    }
}
