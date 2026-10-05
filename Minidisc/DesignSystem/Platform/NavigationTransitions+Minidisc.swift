import SwiftUI

extension View {
    @ViewBuilder
    func minidiscZoomTransition(sourceID: String?, in namespace: Namespace.ID?) -> some View {
        if let sourceID, let namespace {
            self.navigationTransition(.zoom(sourceID: sourceID, in: namespace))
        } else {
            self
        }
    }

    @ViewBuilder
    func minidiscMatchedTransitionSource(id: String?, in namespace: Namespace.ID?) -> some View {
        if let id, let namespace {
            self.matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
    }
}
