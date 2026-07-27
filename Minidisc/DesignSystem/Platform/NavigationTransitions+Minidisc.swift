// Minidisc — Music client for Subsonic/OpenSubsonic servers
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

extension View {
    /// Applies a zoom navigation transition.
    @ViewBuilder
    func minidiscZoomTransition(sourceID: String?, in namespace: Namespace.ID?) -> some View {
        if let sourceID, let namespace {
            self.navigationTransition(.zoom(sourceID: sourceID, in: namespace))
        } else {
            self
        }
    }

    /// Marks this view as the matched transition source for a zoom navigation (iOS 18+).
    /// No-op when either parameter is nil.
    @ViewBuilder
    func minidiscMatchedTransitionSource(id: String?, in namespace: Namespace.ID?) -> some View {
        if let id, let namespace {
            self.matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
    }
}
