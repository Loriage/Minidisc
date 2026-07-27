import SwiftUI

/// Visual affordance signalling that a list row can be drag-reordered.
///
/// Purely visual — the host view owns the actual reorder (SwiftUI `List.onMove`, or
/// `.onDrag`/`.onDrop` + a `DropDelegate`) and any haptics. Drop it at a row's trailing edge.
///
/// Pass `isActive` for the dragged/active state where the host tracks it (e.g. edit-pinned's
/// `draggedItem`); `List.onMove` has no clean per-row drag state, so queue rows use the default.
struct ReorderIndicator: View {
    /// When true, the grip tints with the playing accent (host-driven drag state).
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
