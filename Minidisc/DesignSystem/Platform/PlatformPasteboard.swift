// Minidisc
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import UIKit

/// Cross-platform clipboard abstraction.
/// Mirrors the PlatformImage pattern: one call site, two platform implementations.
nonisolated enum PlatformPasteboard {
    /// Copies `string` to the system clipboard.
    static func copy(_ string: String) {
        UIPasteboard.general.string = string
    }
}
