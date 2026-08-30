import SwiftUI
import UIKit

/// Presents UIKit's native activity controller for content prepared asynchronously.
/// `UIActivityViewController` requires type erasure at this framework boundary; callers remain generic.
struct SystemShareSheet<Item>: UIViewControllerRepresentable {
    let item: Item

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [item as Any], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
