// Minidisc — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

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
