import AVFoundation
import Foundation

/// Copies only technical values; AVFoundation logs can also contain signed URLs and server messages.
nonisolated struct AudioEngineDiagnosticSnapshot: Sendable, Equatable {
    enum Trigger: String, Sendable {
        case play, timeControl, itemStatus, queueChanged, preload, preloadCleared, promoted
        case stalled, ended, failedToEnd, accessLog, errorLog, sample, watchdogEnd, reset, routeChanged
    }

    enum Role: String, Sendable {
        case active, queued, standby
    }

    enum WaitingReason: String, Sendable {
        case none, minimizeStalls, evaluateBuffer, noItem, other

        init(_ reason: AVPlayer.WaitingReason?) {
            switch reason {
            case nil: self = .none
            case .toMinimizeStalls: self = .minimizeStalls
            case .evaluatingBufferingRate: self = .evaluateBuffer
            case .noItemToPlay: self = .noItem
            default: self = .other
            }
        }
    }

    let trigger: Trigger
    let token: AudioEnginePlaybackToken
    let role: Role
    let playerStatus: Int
    let itemStatus: Int
    let timeControl: Int
    let waiting: WaitingReason
    let intendedPlayback: Bool
    let isPlayerCurrentItem: Bool
    let airPlay: Bool
    let externalPlayback: Bool
    let queueCount: Int
    let advanceAtEnd: Bool
    let rate: Float
    let position: Double?
    let duration: Double?
    let bufferedAhead: Double?
    let bufferEmpty: Bool
    let bufferFull: Bool
    let likelyToKeepUp: Bool
    let automaticWaiting: Bool
    let preferredBuffer: Double?
    let replayGainTap: Bool
    let playerFailure: AudioEngineFailure
    let itemFailure: AudioEngineFailure
    let access: Access?

    struct Access: Sendable, Equatable {
        let bytes: Int64
        let transferDuration: Double?
        let observedBitrate: Double?
        let indicatedBitrate: Double?
        let stalls: Int
        let requests: Int
        let startupTime: Double?

        init(_ event: AVPlayerItemAccessLogEvent) {
            bytes = event.numberOfBytesTransferred
            transferDuration = AudioEngineDiagnosticSnapshot.valid(event.transferDuration)
            observedBitrate = AudioEngineDiagnosticSnapshot.valid(event.observedBitrate)
            indicatedBitrate = AudioEngineDiagnosticSnapshot.valid(event.indicatedBitrate)
            stalls = event.numberOfStalls
            requests = event.numberOfMediaRequests
            startupTime = AudioEngineDiagnosticSnapshot.valid(event.startupTime)
        }

        var description: String {
            "bytes=\(bytes) transfer-s=\(AudioEngineDiagnosticSnapshot.number(transferDuration)) observed-bps=\(AudioEngineDiagnosticSnapshot.number(observedBitrate)) indicated-bps=\(AudioEngineDiagnosticSnapshot.number(indicatedBitrate)) stalls=\(stalls) requests=\(requests) startup-s=\(AudioEngineDiagnosticSnapshot.number(startupTime))"
        }
    }

    init(trigger: Trigger, token: AudioEnginePlaybackToken, role: Role,
         player: AVQueuePlayer, item: AVPlayerItem, intendedPlayback: Bool,
         airPlay: Bool, replayGainTap: Bool) {
        self.trigger = trigger
        self.token = token
        self.role = role
        playerStatus = player.status.rawValue
        itemStatus = item.status.rawValue
        timeControl = player.timeControlStatus.rawValue
        waiting = WaitingReason(player.reasonForWaitingToPlay)
        self.intendedPlayback = intendedPlayback
        isPlayerCurrentItem = player.currentItem === item
        self.airPlay = airPlay
        externalPlayback = player.isExternalPlaybackActive
        queueCount = player.items().count
        advanceAtEnd = player.actionAtItemEnd == .advance
        rate = player.rate
        position = Self.valid(item.currentTime().seconds)
        duration = Self.valid(item.duration.seconds)
        bufferedAhead = position.map { Self.bufferedSeconds(aheadOf: $0, ranges: item.loadedTimeRanges.map(\.timeRangeValue)) }
        bufferEmpty = item.isPlaybackBufferEmpty
        bufferFull = item.isPlaybackBufferFull
        likelyToKeepUp = item.isPlaybackLikelyToKeepUp
        automaticWaiting = player.automaticallyWaitsToMinimizeStalling
        preferredBuffer = Self.valid(item.preferredForwardBufferDuration)
        self.replayGainTap = replayGainTap
        playerFailure = AudioEngineFailure(error: player.error)
        itemFailure = AudioEngineFailure(error: item.error, logCode: item.errorLog()?.events.last.map {
            AudioEngineFailure.Code(domain: $0.errorDomain, value: $0.errorStatusCode)
        })
        access = item.accessLog()?.events.last.map(Access.init)
    }

    static func bufferedSeconds(aheadOf position: Double, ranges: [CMTimeRange]) -> Double {
        guard position.isFinite, position >= 0 else { return 0 }
        var end = position
        for range in ranges.sorted(by: { $0.start.seconds < $1.start.seconds }) {
            let start = range.start.seconds
            let rangeEnd = CMTimeRangeGetEnd(range).seconds
            guard start.isFinite, rangeEnd.isFinite, start <= end, rangeEnd >= end else { continue }
            end = rangeEnd
        }
        return max(0, end - position)
    }

    private static func valid(_ value: Double) -> Double? {
        value.isFinite && value >= 0 ? value : nil
    }

    private static func number(_ value: Double?) -> String {
        value.map { String(format: "%.2f", $0) } ?? "unknown"
    }

    private static func status(_ value: Int) -> String {
        switch value {
        case 0: "unknown"
        case 1: "ready"
        case 2: "failed"
        default: "other"
        }
    }

    var description: String {
        let control = switch timeControl {
        case 0: "paused"
        case 1: "waiting"
        case 2: "playing"
        default: "other"
        }
        return "engine-detail trigger=\(trigger.rawValue) item=\(token.rawValue) role=\(role.rawValue) current=\(isPlayerCurrentItem) intent-play=\(intendedPlayback) player=\(Self.status(playerStatus)) item-status=\(Self.status(itemStatus)) control=\(control) wait=\(waiting.rawValue) rate=\(rate) position=\(Self.number(position)) duration=\(Self.number(duration)) buffered-ahead=\(Self.number(bufferedAhead)) empty=\(bufferEmpty) full=\(bufferFull) keep-up=\(likelyToKeepUp) queue=\(queueCount) advance-at-end=\(advanceAtEnd) airplay=\(airPlay) external=\(externalPlayback) auto-wait=\(automaticWaiting) preferred-buffer=\(Self.number(preferredBuffer)) gain-tap=\(replayGainTap) player-errors=\(playerFailure.diagnosticDescription) item-errors=\(itemFailure.diagnosticDescription) access={\(access?.description ?? "unavailable")}"
    }
}
