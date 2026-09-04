import Foundation

/// Pure queue-transition policy. It decides what playback should do; `PlayerService` performs the
/// asynchronous work described by the resulting plan.
nonisolated enum PlaybackTransitionPlanner {
    enum Trigger: Equatable, Sendable {
        case nextRequested
        case previousRequested(position: TimeInterval)
        case trackEnded
        case resumeRequested(stoppedAtEndOfQueue: Bool)
    }

    struct Snapshot: Equatable, Sendable {
        let queueCount: Int
        let currentIndex: Int
        let repeatMode: RepeatMode
    }

    enum CurrentTrackOutcome: Equatable, Sendable {
        case skipped
        case completed
    }

    enum Plan: Equatable, Sendable {
        case playQueueItem(index: Int, currentTrackOutcome: CurrentTrackOutcome)
        case restartCurrent
        case repeatCurrent
        case stopAtEnd(currentTrackOutcome: CurrentTrackOutcome)
        case restartQueue
        case resumeCurrent
    }

    static func plan(for trigger: Trigger, snapshot: Snapshot) -> Plan {
        switch trigger {
        case .nextRequested:
            return forwardPlan(snapshot: snapshot, currentTrackOutcome: .skipped)

        case .previousRequested(let position):
            guard position < 3, snapshot.currentIndex > 0 else {
                return .restartCurrent
            }
            return .playQueueItem(index: snapshot.currentIndex - 1, currentTrackOutcome: .skipped)

        case .trackEnded:
            guard snapshot.repeatMode != .one else { return .repeatCurrent }
            return forwardPlan(snapshot: snapshot, currentTrackOutcome: .completed)

        case .resumeRequested(let stoppedAtEndOfQueue):
            return stoppedAtEndOfQueue && snapshot.queueCount > 0 ? .restartQueue : .resumeCurrent
        }
    }

    /// A failed item is never repeated. Each confirmed missing ID is tried at most once
    /// during automatic advancement, including when Repeat All wraps or the queue has duplicates.
    static func nextIndexAfterUnavailableTrack(
        trackIDs: [String],
        currentIndex: Int,
        repeatMode: RepeatMode,
        unavailableTrackIDs: Set<String>
    ) -> Int? {
        guard trackIDs.indices.contains(currentIndex) else { return nil }
        let following = Array(trackIDs.indices.dropFirst(currentIndex + 1))
        let wrapped = repeatMode == .all ? Array(trackIDs.indices.prefix(currentIndex)) : []
        return (following + wrapped).first { !unavailableTrackIDs.contains(trackIDs[$0]) }
    }

    private static func forwardPlan(
        snapshot: Snapshot,
        currentTrackOutcome: CurrentTrackOutcome
    ) -> Plan {
        let nextIndex = snapshot.currentIndex + 1
        if snapshot.queueCount > 0, (0..<snapshot.queueCount).contains(nextIndex) {
            return .playQueueItem(index: nextIndex, currentTrackOutcome: currentTrackOutcome)
        }
        if snapshot.repeatMode == .all, snapshot.queueCount > 0 {
            return .playQueueItem(index: 0, currentTrackOutcome: currentTrackOutcome)
        }
        return .stopAtEnd(currentTrackOutcome: currentTrackOutcome)
    }
}
