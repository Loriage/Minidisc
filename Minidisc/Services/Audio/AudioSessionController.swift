import AVFAudio
import Foundation
import Synchronization

/// Value-only route information; system route descriptions never cross the playback actor.
nonisolated struct AudioRouteOutputSnapshot: Sendable, Equatable {
    let uid: String
    let portType: AVAudioSession.Port
}

/// Configuration is invalidated by a media-services reset even when the source is unchanged.
nonisolated protocol AudioSessionControlling: Sendable {
    var outputs: [AudioRouteOutputSnapshot] { get }
    func activate() throws
    func deactivate()
    func invalidateConfiguration()
}

nonisolated final class SystemAudioSessionController: AudioSessionControlling {
    private let configured = Mutex(false)

    var outputs: [AudioRouteOutputSnapshot] {
        AVAudioSession.sharedInstance().currentRoute.outputs.map {
            AudioRouteOutputSnapshot(uid: $0.uid, portType: $0.portType)
        }
    }

    func activate() throws {
        try configured.withLock { configured in
            let session = AVAudioSession.sharedInstance()
            if !configured {
                // Playback already supports A2DP and AirPlay. HFP options belong to recording.
                try session.setCategory(.playback)
                configured = true
            }
            try session.setActive(true)
        }
    }

    func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func invalidateConfiguration() {
        configured.withLock { $0 = false }
    }
}

nonisolated struct PlaybackAudioRecoveryTiming: Sendable {
    var retryDelay: Duration = .milliseconds(500)
    var routeGrace: Duration = .seconds(10)
    var startupGrace: Duration = .seconds(15)
    var pollInterval: Duration = .milliseconds(100)
}

/// One incident spans notification + item failures and owns one retry budget. Repeated failures
/// cannot create an unlimited chain of new incidents. Only audible progress completes recovery.
nonisolated struct AudioSystemRecovery {
    static let maximumAttempts = 3
    let id: UInt64
    let deadline: ContinuousClock.Instant
    let playbackGeneration: UInt64
    let transportIntentGeneration: UInt64
    let trackID: String
    let source: MediaSource
    let duration: TimeInterval
    var position: TimeInterval
    let expectedOutputs: [AudioRouteOutputSnapshot]
    var resumeAfterRouteDisconnect = false
    var token: AudioEnginePlaybackToken?
    var restored = false
    var progressBaseline: TimeInterval?
    var attempts = 0

    /// Never turn a temporary Bluetooth/AirPlay disappearance into playback on the phone speaker.
    func acceptsRoute(_ outputs: [AudioRouteOutputSnapshot]) -> Bool {
        let external = expectedOutputs.filter {
            $0.portType != .builtInSpeaker && $0.portType != .builtInReceiver
        }
        guard !external.isEmpty else { return !outputs.isEmpty }
        let expectedUIDs = Set(external.map(\.uid).filter { !$0.isEmpty })
        if !expectedUIDs.isEmpty {
            return outputs.contains { expectedUIDs.contains($0.uid) }
        }
        return outputs.contains { output in external.contains { $0.portType == output.portType } }
    }
}
