import SwiftUI

/// The host owns reordering and haptics; isActive only changes the grip appearance.
struct ReorderIndicator: View {
    var isActive: Bool = false

    @Environment(\.minidiscPlayingAccent) private var playingAccent

    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.minidiscCaption)
            .foregroundStyle(isActive ? playingAccent : Color.secondary)
            .accessibilityLabel("Reorder")
    }
}

#Preview("Light") {
    HStack(spacing: MinidiscSpacing.l) {
        ReorderIndicator()
        ReorderIndicator(isActive: true)
    }
    .padding()
}

#Preview("Dark") {
    HStack(spacing: MinidiscSpacing.l) {
        ReorderIndicator()
        ReorderIndicator(isActive: true)
    }
    .padding()
    .preferredColorScheme(.dark)
}
