/// A snapshot of an intentional jump within the current playback queue.
///
/// The captured identities prevent a delayed UI action from selecting the wrong item after the queue
/// changes. Indexes remain part of the request because the same song may legitimately appear more than once.
nonisolated struct QueueTrackSelection: Equatable, Sendable {
    let queueGeneration: UInt64
    let queueRevision: UInt64
    let currentIndex: Int
    let currentTrackID: String
    let destinationIndex: Int
    let destinationTrackID: String

    @MainActor
    init?(playerState: PlayerState, destinationIndex: Int, destinationTrackID: String) {
        let queue = playerState.queue
        let currentIndex = playerState.currentIndex
        guard queue.indices.contains(currentIndex),
              queue.indices.contains(destinationIndex),
              currentIndex != destinationIndex,
              let currentTrack = playerState.currentTrack,
              queue[currentIndex].id == currentTrack.id,
              queue[destinationIndex].id == destinationTrackID else {
            return nil
        }

        self.queueGeneration = playerState.queueGeneration
        self.queueRevision = playerState.queueRevision
        self.currentIndex = currentIndex
        self.currentTrackID = currentTrack.id
        self.destinationIndex = destinationIndex
        self.destinationTrackID = destinationTrackID
    }

    /// Resolves only while the current and destination positions still represent the captured intent.
    @MainActor
    func resolve(in playerState: PlayerState) -> Int? {
        let queue = playerState.queue
        guard playerState.queueGeneration == queueGeneration,
              playerState.queueRevision == queueRevision,
              playerState.currentIndex == currentIndex,
              playerState.currentTrack?.id == currentTrackID,
              queue.indices.contains(currentIndex),
              queue[currentIndex].id == currentTrackID,
              queue.indices.contains(destinationIndex),
              queue[destinationIndex].id == destinationTrackID else {
            return nil
        }
        return destinationIndex
    }
}
