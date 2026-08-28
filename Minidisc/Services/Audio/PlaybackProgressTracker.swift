import Foundation

nonisolated struct PlaybackProgressTracker {
    private static let maximumContinuousDelta: TimeInterval = 2
    private static let minimumEventDuration: TimeInterval = 30
    private static let maximumScrobbleThreshold: TimeInterval = 240

    private(set) var accumulatedTime: TimeInterval = 0
    private(set) var trackStartDate: Date?
    private var lastProgress: TimeInterval?
    private var didReachScrobbleThreshold = false

    mutating func startTrack(at date: Date = Date()) {
        accumulatedTime = 0
        trackStartDate = date
        lastProgress = nil
        didReachScrobbleThreshold = false
    }

    /// Starts tracking an item that was already audible on a standby deck during a crossfade.
    /// `baseline` is the item's real media position; `accumulatedTime` excludes any lead-in seek.
    mutating func startTrack(
        at date: Date,
        baseline: TimeInterval,
        accumulatedTime: TimeInterval
    ) {
        self.accumulatedTime = Self.isValid(accumulatedTime) ? accumulatedTime : 0
        trackStartDate = date
        lastProgress = Self.isValid(baseline) ? baseline : nil
        didReachScrobbleThreshold = false
    }

    mutating func reset() {
        accumulatedTime = 0
        trackStartDate = nil
        lastProgress = nil
        didReachScrobbleThreshold = false
    }

    mutating func breakContinuity() {
        lastProgress = nil
    }

    mutating func resume(at progress: TimeInterval, startedAt date: Date = Date()) {
        if trackStartDate == nil {
            trackStartDate = date
        }
        setBaseline(progress)
    }

    mutating func establishBaselineIfNeeded(_ progress: TimeInterval) {
        guard lastProgress == nil else { return }
        setBaseline(progress)
    }

    mutating func setBaseline(_ progress: TimeInterval) {
        lastProgress = Self.isValid(progress) ? progress : nil
    }

    mutating func record(progress: TimeInterval, isPlaying: Bool) {
        guard Self.isValid(progress) else { return }
        guard isPlaying else {
            breakContinuity()
            return
        }
        guard let previous = lastProgress else {
            lastProgress = progress
            return
        }

        let delta = progress - previous
        if delta >= 0, delta <= Self.maximumContinuousDelta {
            accumulatedTime += delta
        }
        lastProgress = progress
    }

    mutating func scrobbleStartDateIfThresholdMet(
        trackDuration: TimeInterval,
        fallbackDate: Date = Date()
    ) -> Date? {
        guard !didReachScrobbleThreshold,
              trackDuration >= Self.minimumEventDuration,
              accumulatedTime >= min(Self.maximumScrobbleThreshold, trackDuration * 0.5) else {
            return nil
        }
        didReachScrobbleThreshold = true
        return trackStartDate ?? fallbackDate
    }

    func playbackEvent(
        song: DisplayableSong,
        trackDuration: TimeInterval,
        wasCompleted: Bool,
        serverId: UUID
    ) -> PlaybackEventDTO? {
        guard accumulatedTime >= Self.minimumEventDuration,
              let trackStartDate else {
            return nil
        }
        return PlaybackEventDTO(
            trackId: song.id,
            trackTitle: song.title,
            albumId: song.albumId,
            albumTitle: song.albumName,
            artistId: song.artistId,
            artistName: song.artist ?? "",
            genre: song.genre,
            timestamp: trackStartDate,
            durationListened: accumulatedTime,
            trackDuration: trackDuration,
            wasCompleted: wasCompleted,
            serverId: serverId.uuidString
        )
    }

    private static func isValid(_ progress: TimeInterval) -> Bool {
        progress.isFinite && progress >= 0
    }
}
