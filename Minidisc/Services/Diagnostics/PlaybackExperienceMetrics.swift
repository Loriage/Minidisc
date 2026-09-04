import Foundation

/// Aggregate measurements for this process only. No titles, IDs, URLs or listening history.
/// Startup means observed playhead advancement, not AVPlayer's optimistic `playing` callback.
nonisolated struct PlaybackExperienceMetrics: Sendable {
    private(set) var starts = 0
    private(set) var failedStarts = 0
    private(set) var interruptions = 0
    private(set) var startupDurations: [TimeInterval] = []
    private var requestedAt: TimeInterval?
    private var baseline: TimeInterval?
    private var wantsPlayback = false
    private var hasProgress = false
    private var isInterrupted = false

    mutating func observe(_ event: PlaybackDiagnostics.Event, elapsed: TimeInterval) {
        switch event {
        case .command(.play), .command(.playRadio), .command(.resume):
            starts += 1
            requestedAt = elapsed
            baseline = nil
            wantsPlayback = true
            hasProgress = false
            isInterrupted = false
        case .command(.pause), .command(.stop), .playbackStateChanged(.paused), .playbackStateChanged(.idle):
            wantsPlayback = false
            requestedAt = nil
            baseline = nil
            isInterrupted = false
        case .playbackStateChanged(.error):
            if requestedAt != nil { failedStarts += 1 }
            requestedAt = nil
            wantsPlayback = false
            isInterrupted = false
        case .engineStateChanged(.buffering), .engineStateChanged(.paused), .engineStateChanged(.error):
            if wantsPlayback, hasProgress, !isInterrupted {
                interruptions += 1
                isInterrupted = true
            }
            // Rebuilds can rewind the physical item, and a seek must not count as progress.
            baseline = nil
        default: break
        }
    }

    mutating func observeProgress(_ position: TimeInterval, elapsed: TimeInterval) {
        guard wantsPlayback, position.isFinite else { return }
        defer { baseline = position }
        guard let baseline, position > baseline + 0.05, position - baseline < 3 else { return }
        hasProgress = true
        isInterrupted = false
        if let requestedAt {
            startupDurations.append(max(0, elapsed - requestedAt))
            if startupDurations.count > 100 { startupDurations.removeFirst() }
            self.requestedAt = nil
        }
    }

    func percentile(_ fraction: Double) -> TimeInterval? {
        guard !startupDurations.isEmpty else { return nil }
        let values = startupDurations.sorted()
        return values[min(values.count - 1, max(0, Int(ceil(Double(values.count) * fraction)) - 1))]
    }

    var report: String {
        let median = percentile(0.5).map { String(format: "%.2fs", $0) } ?? "n/a"
        let p95 = percentile(0.95).map { String(format: "%.2fs", $0) } ?? "n/a"
        return "Experience (this launch): starts=\(starts) failed-starts=\(failedStarts) interruptions=\(interruptions) progress-confirmed-startup samples=\(startupDurations.count) p50=\(median) p95=\(p95) sampling=0.5s"
    }
}
