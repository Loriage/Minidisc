import SwiftUI
import UIKit

private struct SwipeBackEnablerRepresentable: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        DispatchQueue.main.async {
            uiViewController.navigationController?.interactivePopGestureRecognizer?.isEnabled = true
            uiViewController.navigationController?.interactivePopGestureRecognizer?.delegate = nil
        }
    }
}

extension View {
    func enableSwipeBack() -> some View {
        background(SwipeBackEnablerRepresentable())
    }
}
