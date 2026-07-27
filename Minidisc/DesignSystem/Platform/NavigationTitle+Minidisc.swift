import SwiftUI

extension View {
    /// Sets navigation title display mode to inline.
    func navigationBarTitleDisplayModeInline() -> some View {
        self.navigationBarTitleDisplayMode(.inline)
    }

    /// Sets navigation title display mode to large.
    func navigationBarTitleDisplayModeLarge() -> some View {
        self.navigationBarTitleDisplayMode(.large)
    }
}
