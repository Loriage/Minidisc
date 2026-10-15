import SwiftUI

/// A short all-caps audio format label (FLAC, MP3, ALAC). Lossless formats use `minidiscLossless`.
struct FormatBadge: View {
    let format: String

    private var isLossless: Bool { AudioFormatInfo.isLossless(format) }

    var body: some View {
        Text(verbatim: format.uppercased())
            .font(.minidiscBadge)
            .foregroundStyle(isLossless ? AnyShapeStyle(Color.minidiscLossless) : AnyShapeStyle(.secondary))
            .padding(.horizontal, MinidiscSpacing.s - 2)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(isLossless ? AnyShapeStyle(Color.minidiscLossless.opacity(0.18)) : AnyShapeStyle(.primary.opacity(0.12)))
            )
            .accessibilityLabel(Text(isLossless ? "\(format.uppercased()), lossless" : "\(format.uppercased())"))
    }
}

/// Format facts shared by the badge and the player's format line.
nonisolated enum AudioFormatInfo {
    private static let losslessFormats: Set<String> = [
        "flac", "alac", "wav", "wave", "aif", "aiff", "ape", "wv", "dsf", "dff", "tta", "shn"
    ]

    static func isLossless(_ format: String) -> Bool {
        losslessFormats.contains(format.lowercased())
    }
}

#Preview {
    HStack {
        FormatBadge(format: "flac")
        FormatBadge(format: "mp3")
    }
    .padding()
    .background(Color.black)
    .environment(\.colorScheme, .dark)
}
