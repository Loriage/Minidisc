import UIKit

/// Cross-platform clipboard abstraction.
/// Mirrors the PlatformImage pattern: one call site, two platform implementations.
nonisolated enum PlatformPasteboard {
    /// Copies `string` to the system clipboard.
    static func copy(_ string: String) {
        UIPasteboard.general.string = string
    }
}
