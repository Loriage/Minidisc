import SwiftUI
import SwiftSonic
import UIKit

struct PlayerArtworkSnapshot {
    let id: String
    let image: PlatformImage
}

/// AMPlayer's accessory → overlay → accessory lifecycle. Only presentation state lives here;
/// playback progress never invalidates the TabView that owns this object.
@MainActor
@Observable
final class PlayerContainerConfiguration {
    var minimisedPlayerRect: CGRect = .zero
    var minimisedPlayerIsInline = false
    var accessoryColorScheme: ColorScheme = .light
    private(set) var attachExpandedPlayer = false
    private(set) var expandPlayer = false
    var dragOffset: CGFloat = 0
    @ObservationIgnored var transitionArtwork: PlayerArtworkSnapshot?

    func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .interpolatingSpring(duration: 0.3, bounce: 0, initialVelocity: 0)
    }

    func present(artwork: PlayerArtworkSnapshot?) {
        guard !attachExpandedPlayer, minimisedPlayerRect.width > 0 else { return }
        transitionArtwork = artwork
        attachExpandedPlayer = true
    }

    func expand(reduceMotion: Bool) {
        guard attachExpandedPlayer, !expandPlayer else { return }
        withAnimation(animation(reduceMotion: reduceMotion)) {
            expandPlayer = true
        }
    }

    func dismiss(reduceMotion: Bool) {
        guard expandPlayer else { return }
        withAnimation(animation(reduceMotion: reduceMotion), completionCriteria: .removed) {
            dragOffset = 0
            expandPlayer = false
        } completion: {
            // The morph has already reached the accessory. Reattaching it must not start
            // a second insertion animation in the TabView or the mini-player's content.
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                self.attachExpandedPlayer = false
            }
        }
    }

    func reset() {
        expandPlayer = false
        attachExpandedPlayer = false
        dragOffset = 0
    }
}

struct PlayerContainer: View {
    let configuration: PlayerContainerConfiguration
    @Environment(\.appContainer) private var container
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @Environment(\.colorScheme) private var colorScheme
    @Namespace private var artworkNamespace

    var body: some View {
        if configuration.attachExpandedPlayer {
            expandedContainer
        } else {
            // Measure the system's accessory proposal, not the mini-player's intrinsic
            // content height: its metadata/padding can extend beyond the glass capsule.
            Color.clear
                .overlay { miniPlayer(isAttached: false) }
                .contentShape(.rect)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("player.accessory")
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rect in
                    guard !configuration.attachExpandedPlayer, rect.width > 0, rect.height > 0 else { return }
                    configuration.minimisedPlayerRect = rect
                }
                .onChange(of: placement, initial: true) {
                    guard !configuration.attachExpandedPlayer else { return }
                    configuration.minimisedPlayerIsInline = placement == .inline
                }
                .onChange(of: colorScheme, initial: true) {
                    guard !configuration.attachExpandedPlayer else { return }
                    configuration.accessoryColorScheme = colorScheme
                }
        }
    }

    private var expandedContainer: some View {
        let expanded = configuration.expandPlayer
        let rect = configuration.minimisedPlayerRect
        let shape = ConcentricRectangle(
            corners: .concentric(minimum: .fixed(rect.height / 2)), isUniform: true
        )
        return GeometryReader { geometry in
            let safeArea = geometry.safeAreaInsets
            let size = CGSize(width: geometry.size.width + safeArea.leading + safeArea.trailing,
                              height: geometry.size.height + safeArea.top + safeArea.bottom)
            ZStack {
                if expanded {
                    FullPlayerView(artworkNamespace: reduceMotion ? nil : artworkNamespace,
                                   contentInsets: safeArea, initialArtwork: configuration.transitionArtwork,
                                   dismissAction: dismiss)
                        .toastOverlay(reservesMiniPlayerSpace: false)
                        .geometryGroup()
                        .transition(.opacity)
                }
            }
            .frame(width: expanded ? size.width : rect.width,
                   height: expanded ? size.height : rect.height)
            .overlay(alignment: .top) {
                if !expanded {
                    miniPlayer(isAttached: true)
                        .environment(\.colorScheme, configuration.accessoryColorScheme)
                        .frame(height: rect.height)
                        .geometryGroup()
                        .transition(.opacity)
                }
            }
            .contentShape(shape)
            .clipShape(shape)
            // The expanded player already has an opaque artwork background. Glass is
            // only needed for the mini capsule; its rim would outline the entire screen.
            .glassEffect(expanded ? .identity : .regular, in: shape)
            .modifier(PlayerContainerPosition(configuration: configuration, expanded: expanded,
                                              minimisedRect: rect))
            .gesture(PlayerDismissGesture { translation in
                configuration.dragOffset = max(0, translation.y)
            } onEnded: { velocity in
                let projectedOffset = configuration.dragOffset + max(velocity.y / 5, 0)
                if projectedOffset > size.height / 2 {
                    dismiss()
                } else {
                    restorePosition()
                }
            } onCancelled: {
                restorePosition()
            })
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("player.presentation")
            .accessibilityAddTraits(.isModal)
            .accessibilityAction(.escape, dismiss)
            .ignoresSafeArea()
        }
        .task {
            // Mount the overlay at the measured accessory rect before animating its expansion.
            await Task.yield()
            guard !Task.isCancelled else { return }
            configuration.expand(reduceMotion: reduceMotion)
        }
    }

    private func miniPlayer(isAttached: Bool) -> some View {
        MiniPlayerAccessoryView(
            showingFullPlayer: isAttached,
            artworkNamespace: reduceMotion ? nil : artworkNamespace,
            initialArtwork: configuration.transitionArtwork,
            placementOverride: isAttached ? configuration.minimisedPlayerIsInline : nil
        ) {
            configuration.present(artwork: artworkSnapshot())
        }
    }

    private func dismiss() {
        configuration.transitionArtwork = artworkSnapshot()
        configuration.dismiss(reduceMotion: reduceMotion)
    }

    // Take a snapshot in the action, not body: observing the cache would redraw the player
    // whenever any unrelated artwork finishes loading elsewhere in the app.
    private func artworkSnapshot() -> PlayerArtworkSnapshot? {
        guard let container else { return nil }
        let state = container.playerState
        let id = state.isLiveStream ? state.currentRadio?.coverArt
            : (state.currentTrack?.coverArtId ?? state.currentTrack?.id)
        guard let id,
              let image = container.artworkImageCache.cachedImage(for: id, tier: .hero)
                ?? container.artworkImageCache.cachedImage(for: id, tier: .thumb) else { return nil }
        return PlayerArtworkSnapshot(id: id, image: image)
    }

    private func restorePosition() {
        withAnimation(configuration.animation(reduceMotion: reduceMotion)) {
            configuration.dragOffset = 0
        }
    }
}

/// Observe the drag at the rendering boundary, keeping AMPlayer's offsets in one coordinate space.
private struct PlayerContainerPosition: ViewModifier {
    let configuration: PlayerContainerConfiguration
    let expanded: Bool
    let minimisedRect: CGRect

    func body(content: Content) -> some View {
        let dragOffset = configuration.dragOffset
        content.visualEffect { content, proxy in
            let globalRect = proxy.frame(in: .global)
            return content
                .offset(y: dragOffset)
                .offset(x: expanded ? 0 : minimisedRect.minX - globalRect.minX,
                        y: expanded ? 0 : minimisedRect.minY - globalRect.minY)
        }
    }
}

struct PlayerArtworkTransition: ViewModifier {
    let namespace: Namespace.ID?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let namespace {
            content.matchedGeometryEffect(id: "playerArtwork", in: namespace)
        } else {
            content
        }
    }
}

/// Keep AMPlayer's pan-driven dismissal while letting the queue, lyrics, seek/volume sliders,
/// and horizontal track swipes own their gestures.
private struct PlayerDismissGesture: UIGestureRecognizerRepresentable {
    var onChanged: (CGPoint) -> Void
    var onEnded: (CGPoint) -> Void
    var onCancelled: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let gesture = UIPanGestureRecognizer()
        gesture.maximumNumberOfTouches = 1
        gesture.delegate = context.coordinator
        return gesture
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {}

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .began, .changed: onChanged(recognizer.translation(in: recognizer.view))
        case .ended: onEnded(recognizer.velocity(in: recognizer.view))
        case .cancelled, .failed: onCancelled()
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return velocity.y > 0 && velocity.y > abs(velocity.x)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let current = view, current !== gestureRecognizer.view {
                if current is UIScrollView || current is UIControl { return false }
                view = current.superview
            }
            return true
        }
    }
}
