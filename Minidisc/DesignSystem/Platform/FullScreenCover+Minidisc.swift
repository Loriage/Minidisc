import SwiftUI

extension View {
    /// Presents a full-screen modal.
    @ViewBuilder
    func minidiscFullScreenCover<Content: View>(
        isPresented: Binding<Bool>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        self.fullScreenCover(isPresented: isPresented, onDismiss: onDismiss, content: content)
    }
}
