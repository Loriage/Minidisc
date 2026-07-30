import SwiftUI

/// Primary action button — accent capsule with play icon. Used in album and playlist headers.
struct PlayButton: View {
    let action: () -> Void
    var label: LocalizedStringKey = "Play"
    var systemImage: String = "play.fill"
    var isDisabled: Bool = false
    var accentColor: Color = MinidiscColors.accent
    /// Label/glyph color. Default white (`minidiscAccentText`) preserves existing callers; the hero passes the
    /// contrast variant's foreground (the cover's dominant color on a dark cover).
    var labelColor: Color = Color.minidiscAccentText
    /// Fixed capsule height. When set, the capsule fills exactly this height (so it can match a
    /// sibling like a 44 pt circle); when nil, the capsule sizes to its label + vertical padding.
    var height: CGFloat? = nil

    var body: some View {
        Button {
            HapticFeedback.medium.trigger()
            action()
        } label: {
            sizedLabel
                .background(isDisabled ? accentColor.opacity(0.4) : accentColor)
                .clipShape(Capsule())
                // The hero passes a white capsule, which would vanish on an album/playlist whose theme colour
                // is white; a faint shadow lifts it off the background without tinting it.
                .shadow(color: .black.opacity(isDisabled ? 0.06 : 0.14), radius: 3, y: 1)
        }
        .disabled(isDisabled)
    }

    @ViewBuilder
    private var sizedLabel: some View {
        let base = Label(label, systemImage: systemImage)
            .font(.minidiscCellTitle)
            .foregroundStyle(labelColor)
            .frame(maxWidth: .infinity)
        if let height {
            base.frame(height: height)
        } else {
            base.padding(.vertical, MinidiscSpacing.m)
        }
    }
}

#Preview {
    VStack(spacing: MinidiscSpacing.l) {
        PlayButton(action: {})
        PlayButton(action: {}, label: "Shuffle", isDisabled: true)
    }
    .padding()
}
