import Observation
import OSLog
import SwiftUI
import UIKit

@Observable
@MainActor
final class TrackSwipeInteraction {
    enum Direction: Equatable {
        case previous
        case next
    }

    struct Destination {
        let song: DisplayableSong
        let selection: QueueTrackSelection
    }

    var offset: CGFloat = 0
    var pageWidth: CGFloat = 0
    var isHorizontalDragActive = false
    private(set) var keepsPauseIcon = false
    private var isCommitting = false

    func destination(_ direction: Direction, in playerState: PlayerState) -> Destination? {
        let queue = playerState.queue
        let currentIndex = playerState.currentIndex
        guard queue.indices.contains(currentIndex), queue.count > 1 else { return nil }

        let candidateIndex = direction == .previous ? currentIndex - 1 : currentIndex + 1
        let destinationIndex: Int
        if queue.indices.contains(candidateIndex) {
            destinationIndex = candidateIndex
        } else {
            guard direction == .next, playerState.repeatMode == .all else { return nil }
            destinationIndex = 0
        }

        let song = queue[destinationIndex]
        guard let selection = QueueTrackSelection(
            playerState: playerState,
            destinationIndex: destinationIndex,
            destinationTrackID: song.id
        ) else {
            return nil
        }
        return Destination(song: song, selection: selection)
    }

    func changed(translation: CGSize, playerState: PlayerState) {
        guard !isCommitting,
              pageWidth > 0,
              abs(translation.width) > abs(translation.height) else {
            return
        }

        isHorizontalDragActive = true
        let drag = activeTranslation(translation.width)
        guard drag != 0 else {
            offset = 0
            return
        }

        let direction = direction(for: drag)
        if destination(direction, in: playerState) == nil {
            offset = drag * 0.12
        } else {
            offset = min(max(drag, -pageWidth), pageWidth)
        }
    }

    func ended(
        translation: CGSize,
        predictedTranslation: CGSize,
        playerState: PlayerState,
        playerService: (any PlayerServiceProtocol)?,
        reduceMotion: Bool
    ) {
        defer { isHorizontalDragActive = false }
        guard !isCommitting else { return }
        guard abs(translation.width) > abs(translation.height) else {
            bounceBack(reduceMotion: reduceMotion)
            return
        }

        let drag = activeTranslation(translation.width)
        let direction = direction(for: drag)
        let predictedDrag = activeTranslation(predictedTranslation.width)
        let shouldCommit = abs(drag) >= min(90, pageWidth * 0.30)
            || abs(predictedDrag) >= pageWidth * 0.50

        if shouldCommit {
            commit(
                direction,
                playerState: playerState,
                playerService: playerService,
                reduceMotion: reduceMotion
            )
        } else {
            bounceBack(reduceMotion: reduceMotion)
        }
    }

    func skip(
        _ direction: Direction,
        playerState: PlayerState,
        playerService: (any PlayerServiceProtocol)?,
        reduceMotion: Bool
    ) {
        commit(
            direction,
            playerState: playerState,
            playerService: playerService,
            reduceMotion: reduceMotion
        )
    }

    func reset() {
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            offset = 0
            isHorizontalDragActive = false
            keepsPauseIcon = false
            isCommitting = false
        }
    }

    func cancel(reduceMotion: Bool) {
        isHorizontalDragActive = false
        bounceBack(reduceMotion: reduceMotion)
    }

    private func commit(
        _ direction: Direction,
        playerState: PlayerState,
        playerService: (any PlayerServiceProtocol)?,
        reduceMotion: Bool
    ) {
        guard !isCommitting,
              let destination = destination(direction, in: playerState),
              let playerService else {
            bounceBack(reduceMotion: reduceMotion)
            return
        }

        isCommitting = true
        keepsPauseIcon = playerState.playbackState == .playing
        HapticFeedback.medium.trigger()
        withAnimation(reduceMotion ? .easeOut(duration: 0.08) : .snappy(duration: 0.22)) {
            offset = direction == .next ? -pageWidth : pageWidth
        }

        Task { @MainActor in
            if !reduceMotion {
                try? await Task.sleep(for: .milliseconds(150))
            }
            do {
                let selected = try await playerService.selectQueueTrack(destination.selection)
                keepsPauseIcon = false
                if !selected {
                    isCommitting = false
                    bounceBack(reduceMotion: reduceMotion)
                }
            } catch {
                Logger.player.error("[TRANSITION] swipe selection failed: \(error, privacy: .public)")
                keepsPauseIcon = false
                isCommitting = false
                bounceBack(reduceMotion: reduceMotion)
            }
        }
    }

    private func direction(for translation: CGFloat) -> Direction {
        translation < 0 ? .next : .previous
    }

    private func activeTranslation(_ translation: CGFloat) -> CGFloat {
        guard abs(translation) > MinidiscSpacing.xl else { return 0 }
        return translation > 0
            ? translation - MinidiscSpacing.xl
            : translation + MinidiscSpacing.xl
    }

    private func bounceBack(reduceMotion: Bool) {
        withAnimation(reduceMotion ? .easeOut(duration: 0.08) : .spring(response: 0.30, dampingFraction: 0.78)) {
            offset = 0
        }
    }
}

extension View {
    @ViewBuilder
    func trackSwipeGesture(
        interaction: TrackSwipeInteraction,
        playerState: PlayerState,
        playerService: (any PlayerServiceProtocol)?,
        reduceMotion: Bool,
        isEnabled: Bool,
        pageWidth: CGFloat? = nil
    ) -> some View {
        if isEnabled {
            gesture(
                HorizontalTrackPanGesture(
                    interaction: interaction,
                    playerState: playerState,
                    playerService: playerService,
                    reduceMotion: reduceMotion,
                    pageWidth: pageWidth
                )
            )
        } else {
            self
        }
    }
}

private struct HorizontalTrackPanGesture: UIGestureRecognizerRepresentable {
    let interaction: TrackSwipeInteraction
    let playerState: PlayerState
    let playerService: (any PlayerServiceProtocol)?
    let reduceMotion: Bool
    let pageWidth: CGFloat?

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.delegate = context.coordinator
        recognizer.maximumNumberOfTouches = 1
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        context.coordinator.parent = self
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let point = recognizer.translation(in: recognizer.view)
        let translation = CGSize(width: point.x, height: point.y)

        switch recognizer.state {
        case .began, .changed:
            if let pageWidth, pageWidth > 0 {
                interaction.pageWidth = pageWidth
            }
            interaction.changed(translation: translation, playerState: playerState)

        case .ended:
            let velocity = recognizer.velocity(in: recognizer.view)
            interaction.ended(
                translation: translation,
                predictedTranslation: CGSize(
                    width: translation.width + velocity.x * 0.2,
                    height: translation.height + velocity.y * 0.2
                ),
                playerState: playerState,
                playerService: playerService,
                reduceMotion: reduceMotion
            )

        case .cancelled, .failed:
            interaction.cancel(reduceMotion: reduceMotion)

        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: HorizontalTrackPanGesture

        init(parent: HorizontalTrackPanGesture) {
            self.parent = parent
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y)
        }
    }
}

struct SwipeableTrackMetadata<Content: View>: View {
    let playerState: PlayerState
    let playerService: (any PlayerServiceProtocol)?
    let interaction: TrackSwipeInteraction
    private let content: (DisplayableSong?, Bool) -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var viewportWidth: CGFloat = 0

    init(
        playerState: PlayerState,
        playerService: (any PlayerServiceProtocol)?,
        interaction: TrackSwipeInteraction,
        @ViewBuilder content: @escaping (DisplayableSong?, Bool) -> Content
    ) {
        self.playerState = playerState
        self.playerService = playerService
        self.interaction = interaction
        self.content = content
    }

    var body: some View {
        // The non-current variant has the same typography without starting a second hidden marquee task.
        content(currentSong, false)
            .hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay {
                GeometryReader { geometry in
                    let width = geometry.size.width
                    HStack(spacing: MinidiscSpacing.xxxl) {
                        page(content(previousSong, false), width: width)
                            .accessibilityHidden(true)
                        page(content(currentSong, true), width: width)
                        page(content(nextSong, false), width: width)
                            .accessibilityHidden(true)
                    }
                    .offset(x: -(width + MinidiscSpacing.xxxl) + interaction.offset)
                    .frame(width: width, height: geometry.size.height, alignment: .leading)
                    .clipped()
                }
            }
            .contentShape(Rectangle())
            .trackSwipeGesture(
                interaction: interaction,
                playerState: playerState,
                playerService: playerService,
                reduceMotion: reduceMotion,
                isEnabled: true,
                pageWidth: viewportWidth > 0 ? pageStride : nil
            )
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                viewportWidth = width
                interaction.pageWidth = width + MinidiscSpacing.xxxl
            }
            .accessibilityAction(named: "Skip to previous") {
                interaction.skip(
                    .previous,
                    playerState: playerState,
                    playerService: playerService,
                    reduceMotion: reduceMotion
                )
            }
            .accessibilityAction(named: "Skip to next") {
                interaction.skip(
                    .next,
                    playerState: playerState,
                    playerService: playerService,
                    reduceMotion: reduceMotion
                )
            }
            .onChange(of: playerState.currentIndex) { _, _ in interaction.reset() }
            .onChange(of: playerState.currentTrack?.id) { _, _ in interaction.reset() }
    }

    private var currentSong: DisplayableSong? {
        playerState.currentTrack
    }

    private var previousSong: DisplayableSong? {
        interaction.destination(.previous, in: playerState)?.song
    }

    private var nextSong: DisplayableSong? {
        interaction.destination(.next, in: playerState)?.song
    }

    private var pageStride: CGFloat {
        viewportWidth + MinidiscSpacing.xxxl
    }

    private func page<Page: View>(_ page: Page, width: CGFloat) -> some View {
        page
            .frame(width: width, alignment: .leading)
            .clipped()
    }
}

struct MarqueeTrackMetadataText: View {
    let text: String
    let font: Font
    let weight: Font.Weight
    let color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var contentWidth: CGFloat = 0
    @State private var viewportWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    private let gap = MinidiscSpacing.xxxl
    private let pointsPerSecond: CGFloat = 30

    var body: some View {
        label
            .hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                GeometryReader { geometry in
                    let overflows = contentWidth > geometry.size.width
                    let movingOffset = overflows ? offset : 0
                    HStack(spacing: gap) {
                        measuredLabel
                            .offset(x: movingOffset)
                        if overflows {
                            label
                                .fixedSize(horizontal: true, vertical: false)
                                .offset(x: movingOffset)
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
                    .clipped()
                    .mask(edgeMask(isMoving: movingOffset < -1, overflows: overflows))
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
            .task(id: AnimationKey(
                text: text,
                contentWidth: contentWidth,
                viewportWidth: viewportWidth,
                reduceMotion: reduceMotion
            )) {
                await animateIfNeeded()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(text))
    }

    private var label: some View {
        Text(text)
            .font(font)
            .fontWeight(weight)
            .foregroundStyle(color)
            .lineLimit(1)
    }

    private var measuredLabel: some View {
        label
            .fixedSize(horizontal: true, vertical: false)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
    }

    private func edgeMask(isMoving: Bool, overflows: Bool) -> some View {
        LinearGradient(
            stops: overflows
                ? [
                    .init(color: isMoving ? .clear : .black, location: 0),
                    .init(color: .black, location: 0.05),
                    .init(color: .black, location: 0.95),
                    .init(color: .clear, location: 1)
                ]
                : [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 1)
                ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private func animateIfNeeded() async {
        resetOffset()
        guard contentWidth > viewportWidth, viewportWidth > 0, !reduceMotion else { return }

        do {
            try await Task.sleep(for: .seconds(1.2))
            while !Task.isCancelled {
                let stride = contentWidth + gap
                let duration = Double(stride / pointsPerSecond)
                withAnimation(.linear(duration: duration)) {
                    offset = -stride
                }
                try await Task.sleep(for: .seconds(duration))
                resetOffset()
                try await Task.sleep(for: .seconds(1))
            }
        } catch {
            resetOffset()
        }
    }

    private func resetOffset() {
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) { offset = 0 }
    }

    private struct AnimationKey: Equatable {
        let text: String
        let contentWidth: CGFloat
        let viewportWidth: CGFloat
        let reduceMotion: Bool
    }
}
