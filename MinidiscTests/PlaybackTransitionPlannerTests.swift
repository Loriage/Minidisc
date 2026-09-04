import Foundation
import Testing
@testable import Minidisc

@Suite("Playback transition planner")
struct PlaybackTransitionPlannerTests {
    @Test func missingTrackNeverRepeatsItself() {
        for mode in [RepeatMode.off, .one, .all] {
            #expect(PlaybackTransitionPlanner.nextIndexAfterUnavailableTrack(
                trackIDs: ["a", "a", "b"], currentIndex: 0, repeatMode: mode,
                unavailableTrackIDs: ["a"]
            ) == 2)
            #expect(PlaybackTransitionPlanner.nextIndexAfterUnavailableTrack(
                trackIDs: ["a", "a", "b"], currentIndex: 2, repeatMode: mode,
                unavailableTrackIDs: ["a", "b"]
            ) == nil)
        }
    }

    @Test func missingLastTrackCanWrapToAnAvailableTrackOnlyInRepeatAll() {
        #expect(PlaybackTransitionPlanner.nextIndexAfterUnavailableTrack(
            trackIDs: ["a", "b"], currentIndex: 1, repeatMode: .all, unavailableTrackIDs: ["b"]
        ) == 0)
        #expect(PlaybackTransitionPlanner.nextIndexAfterUnavailableTrack(
            trackIDs: ["a", "b"], currentIndex: 1, repeatMode: .off, unavailableTrackIDs: ["b"]
        ) == nil)
    }

    private func snapshot(
        queueCount: Int = 4,
        currentIndex: Int = 1,
        repeatMode: RepeatMode = .off
    ) -> PlaybackTransitionPlanner.Snapshot {
        .init(queueCount: queueCount, currentIndex: currentIndex, repeatMode: repeatMode)
    }

    @Test("manual next advances and marks the current track skipped")
    func manualNextAdvances() {
        let plan = PlaybackTransitionPlanner.plan(
            for: .nextRequested,
            snapshot: snapshot()
        )
        #expect(plan == .playQueueItem(index: 2, currentTrackOutcome: .skipped))
    }

    @Test("manual next wraps only in Repeat All")
    func manualNextWrapsInRepeatAll() {
        let plan = PlaybackTransitionPlanner.plan(
            for: .nextRequested,
            snapshot: snapshot(queueCount: 4, currentIndex: 3, repeatMode: .all)
        )
        #expect(plan == .playQueueItem(index: 0, currentTrackOutcome: .skipped))
    }

    @Test("manual next parks at the end when repeat is disabled")
    func manualNextStopsAtEnd() {
        let plan = PlaybackTransitionPlanner.plan(
            for: .nextRequested,
            snapshot: snapshot(queueCount: 4, currentIndex: 3)
        )
        #expect(plan == .stopAtEnd(currentTrackOutcome: .skipped))
    }

    @Test("natural end advances and marks the current track completed")
    func naturalEndAdvances() {
        let plan = PlaybackTransitionPlanner.plan(
            for: .trackEnded,
            snapshot: snapshot()
        )
        #expect(plan == .playQueueItem(index: 2, currentTrackOutcome: .completed))
    }

    @Test("natural end repeats the current track in Repeat One")
    func naturalEndRepeatsCurrent() {
        let plan = PlaybackTransitionPlanner.plan(
            for: .trackEnded,
            snapshot: snapshot(repeatMode: .one)
        )
        #expect(plan == .repeatCurrent)
    }

    @Test("natural end wraps in Repeat All and preserves completion attribution")
    func naturalEndWrapsInRepeatAll() {
        let plan = PlaybackTransitionPlanner.plan(
            for: .trackEnded,
            snapshot: snapshot(queueCount: 4, currentIndex: 3, repeatMode: .all)
        )
        #expect(plan == .playQueueItem(index: 0, currentTrackOutcome: .completed))
    }

    @Test("natural end parks at the end with completion attribution")
    func naturalEndStopsAtEnd() {
        let plan = PlaybackTransitionPlanner.plan(
            for: .trackEnded,
            snapshot: snapshot(queueCount: 4, currentIndex: 3)
        )
        #expect(plan == .stopAtEnd(currentTrackOutcome: .completed))
    }

    @Test("previous navigates backward before three seconds")
    func previousNavigatesBackward() {
        let plan = PlaybackTransitionPlanner.plan(
            for: .previousRequested(position: 2.99),
            snapshot: snapshot(currentIndex: 2)
        )
        #expect(plan == .playQueueItem(index: 1, currentTrackOutcome: .skipped))
    }

    @Test("previous restarts at the three-second threshold")
    func previousRestartsAtThreshold() {
        let plan = PlaybackTransitionPlanner.plan(
            for: .previousRequested(position: 3),
            snapshot: snapshot(currentIndex: 2)
        )
        #expect(plan == .restartCurrent)
    }

    @Test("previous restarts the first queue item")
    func previousRestartsFirstItem() {
        let plan = PlaybackTransitionPlanner.plan(
            for: .previousRequested(position: 0),
            snapshot: snapshot(currentIndex: 0)
        )
        #expect(plan == .restartCurrent)
    }

    @Test("resume after the queue end restarts the queue")
    func resumeAfterEndRestartsQueue() {
        let plan = PlaybackTransitionPlanner.plan(
            for: .resumeRequested(stoppedAtEndOfQueue: true),
            snapshot: snapshot()
        )
        #expect(plan == .restartQueue)
    }

    @Test("ordinary resume keeps the current source")
    func ordinaryResumeKeepsCurrentSource() {
        let plan = PlaybackTransitionPlanner.plan(
            for: .resumeRequested(stoppedAtEndOfQueue: false),
            snapshot: snapshot()
        )
        #expect(plan == .resumeCurrent)
    }

    @Test("an empty queue cannot wrap or restart")
    func emptyQueueStopsOrResumesCurrent() {
        let empty = snapshot(queueCount: 0, currentIndex: 0, repeatMode: .all)
        #expect(PlaybackTransitionPlanner.plan(for: .nextRequested, snapshot: empty)
            == .stopAtEnd(currentTrackOutcome: .skipped))
        #expect(PlaybackTransitionPlanner.plan(
            for: .resumeRequested(stoppedAtEndOfQueue: true),
            snapshot: empty
        ) == .resumeCurrent)
    }
}
