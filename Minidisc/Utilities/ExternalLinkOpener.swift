// Minidisc — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SafariServices
import UIKit

enum ExternalLinkOpener {
    /// Opens a URL in SFSafariViewController.
    @MainActor
    static func open(_ url: URL) {
        guard let presenter = topmostViewController() else { return }
        let safari = SFSafariViewController(url: url)
        safari.modalPresentationStyle = .pageSheet
        presenter.present(safari, animated: true)
    }

    @MainActor
    private static func topmostViewController() -> UIViewController? {
        guard
            let windowScene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
            let root = windowScene.keyWindow?.rootViewController
        else { return nil }
        return topmost(from: root)
    }

    @MainActor
    private static func topmost(from vc: UIViewController) -> UIViewController {
        if let presented = vc.presentedViewController {
            return topmost(from: presented)
        }
        if let nav = vc as? UINavigationController {
            return topmost(from: nav.visibleViewController ?? nav)
        }
        if let tab = vc as? UITabBarController {
            return topmost(from: tab.selectedViewController ?? tab)
        }
        return vc
    }
}
