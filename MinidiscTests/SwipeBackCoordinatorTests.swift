import Testing
import UIKit
@testable import Minidisc

@Suite("Swipe back ownership")
@MainActor
struct SwipeBackCoordinatorTests {
    @Test func rootCannotBeginAndDismantlingRestoresUIKitDelegate() throws {
        let navigation = UINavigationController(rootViewController: UIViewController())
        navigation.loadViewIfNeeded()
        let gesture = try #require(navigation.interactivePopGestureRecognizer)
        let original = gesture.delegate
        gesture.isEnabled = false
        let guardrail = SwipeBackCoordinator()
        guardrail.install(on: navigation)
        #expect(gesture.delegate === guardrail)
        #expect(!guardrail.gestureRecognizerShouldBegin(gesture))
        navigation.setViewControllers([UIViewController(), UIViewController()], animated: false)
        #expect(guardrail.gestureRecognizerShouldBegin(gesture))
        guardrail.restore()
        #expect(gesture.delegate === original)
        #expect(!gesture.isEnabled)
    }

    @Test func disappearingParentCannotRemoveVisibleChildGuard() throws {
        let navigation = UINavigationController(rootViewController: UIViewController())
        navigation.loadViewIfNeeded()
        let gesture = try #require(navigation.interactivePopGestureRecognizer)
        let original = gesture.delegate
        let parent = SwipeBackCoordinator()
        let child = SwipeBackCoordinator()
        parent.install(on: navigation)
        child.install(on: navigation)
        parent.restore()
        #expect(gesture.delegate === child)
        child.restore()
        #expect(gesture.delegate === original)
    }
}
