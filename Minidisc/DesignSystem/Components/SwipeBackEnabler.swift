import SwiftUI
import UIKit

private struct SwipeBackEnablerRepresentable: UIViewControllerRepresentable {
    func makeCoordinator() -> SwipeBackCoordinator { SwipeBackCoordinator() }

    func makeUIViewController(context: Context) -> SwipeBackHostController {
        let controller = SwipeBackHostController()
        controller.coordinator = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: SwipeBackHostController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: SwipeBackHostController, coordinator: SwipeBackCoordinator) {
        coordinator.restore()
    }
}

private final class SwipeBackHostController: UIViewController {
    weak var coordinator: SwipeBackCoordinator?

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if let navigationController { coordinator?.install(on: navigationController) }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        coordinator?.restore()
    }
}

/// Each visible detail owns its guard. Nested details share the original UIKit delegate,
/// rather than retaining one another's coordinators or restoring an obsolete guard.
final class SwipeBackCoordinator: NSObject, UIGestureRecognizerDelegate {
    private weak var navigationController: UINavigationController?
    private weak var previousDelegate: (any UIGestureRecognizerDelegate)?
    private var previousEnabled = false

    func install(on navigationController: UINavigationController) {
        guard let gesture = navigationController.interactivePopGestureRecognizer else { return }
        if self.navigationController === navigationController, gesture.delegate === self { return }
        restore()
        self.navigationController = navigationController
        if let existing = gesture.delegate as? SwipeBackCoordinator {
            previousDelegate = existing.previousDelegate
            previousEnabled = existing.previousEnabled
        } else {
            previousDelegate = gesture.delegate
            previousEnabled = gesture.isEnabled
        }
        gesture.delegate = self
        gesture.isEnabled = true
    }

    func restore() {
        if let gesture = navigationController?.interactivePopGestureRecognizer, gesture.delegate === self {
            gesture.delegate = previousDelegate
            gesture.isEnabled = previousEnabled
        }
        navigationController = nil
        previousDelegate = nil
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let navigationController else { return false }
        return navigationController.viewControllers.count > 1
            && navigationController.transitionCoordinator == nil
    }
}

extension View {
    func enableSwipeBack() -> some View {
        background(SwipeBackEnablerRepresentable())
    }
}
