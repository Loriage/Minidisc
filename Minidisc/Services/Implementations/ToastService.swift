import SwiftUI

enum ToastAction: Equatable, Sendable {
    case navigateToPlaylist(id: String, name: String, coverArtId: String?)
    case navigateToDownloads
    case undoQueueRemoval(QueueRemoval)
}

@MainActor
@Observable
final class ToastService {

    enum Style {
        case info
        case success
        case error

        var systemImage: String {
            switch self {
            case .info:    "info.circle.fill"
            case .success: "checkmark.circle.fill"
            case .error:   "exclamationmark.triangle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .info:    .blue
            case .success: .green
            case .error:   .red
            }
        }
    }

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let message: String
        var subtitle: String? = nil
        let style: Style
        let duration: TimeInterval
        var coverArtId: String? = nil
        var action: ToastAction? = nil
    }

    private(set) var current: Toast?
    private var dismissTask: Task<Void, Never>?

    func show(_ message: String, subtitle: String? = nil, style: Style = .info, duration: TimeInterval = 3.0, coverArtId: String? = nil, action: ToastAction? = nil) {
        dismissTask?.cancel()
        current = Toast(message: message, subtitle: subtitle, style: style, duration: duration, coverArtId: coverArtId, action: action)
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) {
                self?.current = nil
            }
        }
    }

    func showError(_ message: String) {
        show(message, style: .error, duration: 4.0)
    }

    /// A shared boundary for explicit user actions. Callers only apply success UI after true.
    /// Cancellation is an abandoned request, not an error to show to the listener.
    @discardableResult
    func perform(_ operation: () async throws -> Void) async -> Bool {
        do {
            try await operation()
            return true
        } catch {
            if !UserFacingError.isCancellation(error) {
                showError(UserFacingError.from(error).displayMessage)
            }
            return false
        }
    }

    func showSuccess(_ message: String) {
        show(message, style: .success, duration: 2.5)
    }

    func showConfirmation(_ message: String, subtitle: String? = nil, coverArtId: String? = nil, action: ToastAction? = nil) {
        // Tappable toasts dwell a little longer so there is time to tap before auto-dismiss.
        show(message, subtitle: subtitle, style: .success, duration: action == nil ? 2.5 : 4.0, coverArtId: coverArtId, action: action)
    }

    func dismiss() {
        dismissTask?.cancel()
        withAnimation(.easeOut(duration: 0.3)) {
            current = nil
        }
    }
}
