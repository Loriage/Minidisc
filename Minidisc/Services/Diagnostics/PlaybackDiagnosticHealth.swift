import Foundation

/// Observation only: never seeks, resumes, or advances the player.
nonisolated struct PlaybackDiagnosticHealth: Sendable {
    enum Finding: String, Sendable, Equatable {
        case startupNotProgressing = "startup-not-progressing"
        case clockStopped = "clock-stopped"
        case queueHandoffDelayed = "queue-handoff-delayed"
        case progressRecovered = "progress-recovered"
        case samplingGap = "sampling-gap"
    }

    private var token: AudioEnginePlaybackToken?
    private var lastSample: TimeInterval?
    private var lastPosition: Double = 0
    private var lastProgressAt: TimeInterval = 0
    private var reported: Finding?

    mutating func reset() { self = Self() }

    mutating func observe(token: AudioEnginePlaybackToken, position: Double,
                          intended: Bool, waitingAtBoundary: Bool, at time: TimeInterval) -> (Finding, Double)? {
        guard intended, position.isFinite, time.isFinite else { reset(); return nil }
        let gap = lastSample.map { time - $0 }
        if self.token != token || lastSample == nil || (gap ?? 0) > 10 {
            let hadSample = self.token == token && lastSample != nil
            self.token = token
            lastSample = time
            lastPosition = position
            lastProgressAt = time
            reported = nil
            return hadSample ? (.samplingGap, gap ?? 0) : nil
        }
        lastSample = time
        if abs(position - lastPosition) > 0.05 {
            let wasReported = reported != nil
            let elapsed = time - lastProgressAt
            lastPosition = position
            lastProgressAt = time
            reported = nil
            return wasReported ? (.progressRecovered, elapsed) : nil
        }
        let elapsed = time - lastProgressAt
        let finding: Finding = waitingAtBoundary ? .queueHandoffDelayed
            : (position <= 0.05 ? .startupNotProgressing : .clockStopped)
        let threshold: Double = waitingAtBoundary ? 3 : 10
        guard elapsed >= threshold, reported != finding else { return nil }
        reported = finding
        return (finding, elapsed)
    }
}
