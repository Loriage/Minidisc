import Foundation

nonisolated struct QueueRemoval: Equatable, Sendable {
    let queueGeneration: UInt64
    let revisionAfterRemoval: UInt64
    let song: DisplayableSong
    let index: Int
    let originalQueueEndIndex: Int?
}

/// Applies a row's captured intent in a single main-actor transaction. Undo never replaces a
/// queue snapshot: it restores one occurrence, preserving the current track and playback position.
@MainActor
enum QueueEditing {
    static func remove(_ selection: QueueTrackSelection, from state: PlayerState) -> QueueRemoval? {
        guard !state.isLiveStream, let index = selection.resolve(in: state) else { return nil }
        let boundary = state.originalQueueEndIndex
        let song = state.queue.remove(at: index)
        if index < state.currentIndex { state.currentIndex -= 1 }
        if let boundary, index < boundary { state.originalQueueEndIndex = max(0, boundary - 1) }
        return QueueRemoval(queueGeneration: state.queueGeneration, revisionAfterRemoval: state.queueRevision,
                            song: song, index: index, originalQueueEndIndex: boundary)
    }

    static func restore(_ removal: QueueRemoval, in state: PlayerState) -> Bool {
        let expectedBoundary = removal.originalQueueEndIndex.map {
            removal.index < $0 ? max(0, $0 - 1) : $0
        }
        guard !state.isLiveStream,
              state.queueGeneration == removal.queueGeneration,
              state.queueRevision == removal.revisionAfterRemoval,
              state.originalQueueEndIndex == expectedBoundary,
              state.queue.indices.contains(state.currentIndex),
              state.currentTrack?.id == state.queue[state.currentIndex].id,
              (0...state.queue.count).contains(removal.index) else { return false }
        state.queue.insert(removal.song, at: removal.index)
        if removal.index <= state.currentIndex { state.currentIndex += 1 }
        state.originalQueueEndIndex = removal.originalQueueEndIndex
        return true
    }

    static func move(_ selection: QueueTrackSelection, to destination: Int, in state: PlayerState) -> Bool {
        guard !state.isLiveStream, let index = selection.resolve(in: state),
              (0...state.queue.count).contains(destination),
              destination != index, destination != index + 1 else { return false }
        var queue = state.queue
        let song = queue.remove(at: index)
        queue.insert(song, at: index < destination ? destination - 1 : destination)
        if index < state.currentIndex && destination > state.currentIndex { state.currentIndex -= 1 }
        else if index > state.currentIndex && destination <= state.currentIndex { state.currentIndex += 1 }
        state.queue = queue
        state.originalQueueEndIndex = nil
        return true
    }
}
