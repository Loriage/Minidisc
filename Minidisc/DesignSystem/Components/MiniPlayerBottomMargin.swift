// Minidisc — Music client for Subsonic/OpenSubsonic servers
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// Reserves bottom scroll-content space for the floating tabViewBottomAccessory
/// mini player, which overlays tab content without extending the safe area.
/// Mirrors MainTabView.hasTrack so the margin only exists while the bar is shown.
private struct MiniPlayerBottomMargin: ViewModifier {
    @Environment(\.appContainer) private var container

    private var isMiniPlayerVisible: Bool {
        container?.playerState.currentTrack != nil || container?.playerState.isLiveStream == true
    }

    func body(content: Content) -> some View {
        content
            .contentMargins(.bottom, isMiniPlayerVisible ? MinidiscSpacing.miniPlayerBottomMargin : 0, for: .scrollContent)
    }
}

extension View {
    /// Adds bottom scroll margin matching the mini player accessory.
    @ViewBuilder
    func miniPlayerBottomMargin() -> some View {
        modifier(MiniPlayerBottomMargin())
    }
}
