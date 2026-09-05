import Foundation
import SwiftSonic
import Testing
@testable import Minidisc

@Suite("Queue editing and undo")
@MainActor
struct QueueEditingTests {
    @Test("Undo restores the selected occurrence without changing playback")
    func restoresOneOccurrence() throws {
        let state = try makeState(["a", "b", "b", "c"])
        state.originalQueueEndIndex = 3
        let removal = try #require(QueueEditing.remove(selection(state, 2), from: state))
        #expect(state.queue.map(\.id) == ["a", "b", "c"])
        #expect(state.originalQueueEndIndex == 2)
        #expect(QueueEditing.restore(removal, in: state))
        #expect(state.queue.map(\.id) == ["a", "b", "b", "c"])
        #expect(state.originalQueueEndIndex == 3)
        #expect(state.currentTrack?.id == "a")
        #expect(state.position == 42)
        #expect(state.playbackState == .playing)
        #expect(!QueueEditing.restore(removal, in: state))
    }

    @Test("Undo remains valid after Next and keeps the new current track")
    func undoAfterAdvancing() throws {
        let state = try makeState(["a", "b", "c"])
        let removal = try #require(QueueEditing.remove(selection(state, 1), from: state))
        state.currentIndex = 1
        state.currentTrack = state.queue[1]
        state.position = 7
        #expect(QueueEditing.restore(removal, in: state))
        #expect(state.currentTrack?.id == "c")
        #expect(state.currentIndex == 2)
        #expect(state.position == 7)
    }

    @Test("A later structural edit rejects undo instead of replacing that edit")
    func protectsLaterEdits() throws {
        let state = try makeState(["a", "b", "c"])
        let removal = try #require(QueueEditing.remove(selection(state, 1), from: state))
        state.queue.append(state.queue[0])
        #expect(!QueueEditing.restore(removal, in: state))
        #expect(state.queue.map(\.id) == ["a", "c", "a"])
    }

    @Test("A replacement session or changed extension boundary rejects undo")
    func protectsSessionAndBoundary() throws {
        let state = try makeState(["a", "b", "c"])
        state.originalQueueEndIndex = 3
        let removal = try #require(QueueEditing.remove(selection(state, 1), from: state))
        state.originalQueueEndIndex = nil
        #expect(!QueueEditing.restore(removal, in: state))
        state.originalQueueEndIndex = 2
        state.queueGeneration += 1
        #expect(!QueueEditing.restore(removal, in: state))
    }

    @Test("An edit between identical songs invalidates a captured row action")
    func rejectsStaleDuplicateSelection() throws {
        let state = try makeState(["a", "b", "b", "c"])
        let captured = try selection(state, 2)
        state.queue.swapAt(1, 2)
        #expect(QueueEditing.remove(captured, from: state) == nil)
    }

    @Test("Moving an upcoming song preserves current playback and destination semantics")
    func movesUpcomingSong() throws {
        let state = try makeState(["a", "b", "c", "d"])
        #expect(QueueEditing.move(try selection(state, 1), to: 4, in: state))
        #expect(state.queue.map(\.id) == ["a", "c", "d", "b"])
        #expect(state.currentIndex == 0)
        #expect(state.currentTrack?.id == "a")
        #expect(state.position == 42)
        let revision = state.queueRevision
        #expect(!QueueEditing.move(try selection(state, 1), to: 2, in: state))
        #expect(state.queueRevision == revision)
    }

    private func selection(_ state: PlayerState, _ index: Int) throws -> QueueTrackSelection {
        try #require(QueueTrackSelection(playerState: state, destinationIndex: index,
                                        destinationTrackID: state.queue[index].id))
    }

    private func makeState(_ ids: [String]) throws -> PlayerState {
        let state = PlayerState()
        state.queue = try ids.map { id in
            let data = try JSONSerialization.data(withJSONObject: ["id": id, "title": id, "isDir": false])
            return DisplayableSong(from: try JSONDecoder().decode(Song.self, from: data))
        }
        state.currentTrack = state.queue[0]
        state.position = 42
        state.playbackState = .playing
        return state
    }
}
