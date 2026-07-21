// Minidisc — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// Primary action button — accent capsule with play icon. Used in album and playlist headers.
struct PlayButton: View {
    let action: () -> Void
    var label: LocalizedStringKey = "Play"
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
        }
        .disabled(isDisabled)
    }

    @ViewBuilder
    private var sizedLabel: some View {
        let base = Label(label, systemImage: "play.fill")
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
