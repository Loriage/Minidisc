import CryptoKit
import Foundation
import Synchronization

nonisolated enum PlaybackCommandOrigin: String, Sendable {
    case application
    case remotePause = "remote-pause"
    case remoteToggle = "remote-toggle"

    @TaskLocal static var current: PlaybackCommandOrigin = .application
}

/// A bounded timeline with incident captures and optional persistence across launches.
///
/// Events accept only redacted domain values: song metadata, raw URLs, credentials, headers and
/// audio-route names cannot enter the buffer by construction.
nonisolated final class PlaybackDiagnostics: Sendable {
    enum ApplicationEvent: Sendable, Equatable {
        case launchStarted(attempt: Int)
        case servicesReady
        case launchFailed(errorDomain: String, errorCode: Int)
        case lifecycle(Phase)
        enum Phase: String, Sendable { case active, inactive, background, unknown }
    }

    enum MusicIntentEvent: Sendable, Equatable {
        case siriKitResolution
        case siriKitPlayback
        case siriKitSearch
        case unrecognizedMediaIdentifier
        case audioSearch
        case audioPlayback
        case searchStarted
        case searchCompleted(count: Int)
        case selectionPlayback
    }

    enum PlaybackCommand: Sendable, Equatable {
        case play(queueCount: Int, startIndex: Int)
        case playRadio
        case pause
        case resume
        case stop
        case next
        case previous
    }

    enum SourceKind: String, Sendable, Equatable {
        case localFile
        case download
        case cache
        case seekBuffer
        case remoteStream
        case liveStream
    }

    enum CacheEvent: Sendable, Equatable {
        case scheduled(format: CacheFormat, allowsCellular: Bool)
        case started
        case stored
        case alreadyLocal
        case skippedCellular
        case cancelled
        case failed(code: Int)
    }

    enum PlaybackStatus: String, Sendable, Equatable {
        case idle
        case loading
        case playing
        case paused
        case error

        init(_ state: PlaybackState) {
            switch state {
            case .idle: self = .idle
            case .loading: self = .loading
            case .playing: self = .playing
            case .paused: self = .paused
            case .error: self = .error
            }
        }
    }

    enum EngineStatus: String, Sendable, Equatable {
        case playing
        case buffering
        case paused
        case stopped
        case error
    }

    enum NetworkRecoveryEvent: Sendable, Equatable {
        case marked(pathGeneration: UInt64, automatic: Bool)
        case playbackReasserted(pathGeneration: UInt64)
        case attemptStarted(number: Int, pathGeneration: UInt64)
        case sourceRefreshFailed(number: Int, pathGeneration: UInt64)
        case itemRebuilt(number: Int, pathGeneration: UInt64)
        case progressValidated(pathGeneration: UInt64)
        case progressStalled(pathGeneration: UInt64)
        case retryBudgetExhausted(pathGeneration: UInt64)
    }

    enum BoundaryDecision: String, Sendable {
        case stale, liveStream, restoring, duplicate
    }

    enum AudioOutputKind: String, Sendable, Hashable, Comparable {
        case airPlay
        case bluetoothA2DP
        case bluetoothHFP
        case bluetoothLE
        case builtIn
        case carAudio
        case headphones
        case hdmi
        case usb
        case other

        static func < (lhs: AudioOutputKind, rhs: AudioOutputKind) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    enum AudioSessionEvent: Sendable, Equatable {
        case interruptionBegan(routeDisconnected: Bool)
        case interruptionEnded(shouldResume: Bool)
        case interruptionSupersededByPlayback
        case routeChanged(reasonCode: UInt, outputs: [AudioOutputKind])
        case systemPauseArmed(requiresPersonalRoute: Bool)
        case systemResumeAttempted
        case mediaServicesReset
        case mediaServicesLost
        case resetReceived(failedItem: AudioEnginePlaybackToken?)
        case transitionModeChanged(airPlay: Bool)
        case transitionPrepared(crossfade: Bool)
        case recoveryAttemptStarted(number: Int)
        case recoveryActivationFailed(code: Int)
        case recoveryWaitingForRoute
        case recoveryProgressValidated
        case recoveryExhausted
        case recoveryInterrupted
    }

    struct NetworkPath: Sendable, Equatable {
        let generation: UInt64
        let isOnline: Bool
        let isExpensive: Bool
        let isConstrained: Bool
        let supportsDNS: Bool
        let supportsIPv4: Bool
        let supportsIPv6: Bool
        let interfaces: NetworkPathDescriptor.Interfaces

        init(_ event: NetworkPathEvent) {
            generation = event.generation
            isOnline = event.descriptor.isOnline
            isExpensive = event.descriptor.isExpensive
            isConstrained = event.descriptor.isConstrained
            supportsDNS = event.descriptor.supportsDNS
            supportsIPv4 = event.descriptor.supportsIPv4
            supportsIPv6 = event.descriptor.supportsIPv6
            interfaces = event.descriptor.interfaces
        }
    }

    struct ServerEndpoint: Sendable, Equatable {
        enum HostKind: String, Sendable {
            case domain
            case local
            case numeric
            case unknown
        }

        let usesTLS: Bool
        let port: Int?
        let hostKind: HostKind
        let hostFingerprint: String
        let customHeaderCount: Int?

        init(url: URL, customHeaderCount: Int?) {
            let host = url.host?.lowercased() ?? ""
            usesTLS = url.scheme?.lowercased() == "https"
            port = url.port
            hostKind = Self.hostKind(for: host)
            hostFingerprint = Self.fingerprint(host)
            self.customHeaderCount = customHeaderCount
        }

        private static func hostKind(for host: String) -> HostKind {
            guard !host.isEmpty else { return .unknown }
            if host == "localhost" || host.hasSuffix(".local") { return .local }
            if host.contains(":") || host.allSatisfy({ $0.isNumber || $0 == "." }) { return .numeric }
            return .domain
        }

        private static func fingerprint(_ host: String) -> String {
            guard !host.isEmpty else { return "none" }
            return SHA256.hash(data: Data(host.utf8))
                .prefix(6)
                .map { String(format: "%02x", $0) }
                .joined()
        }
    }

    struct ReportContext: Sendable {
        let appVersion: String
        let appBuild: String
        let operatingSystem: String
        let playbackStatus: PlaybackStatus
        let isPlaybackAvailable: Bool
        let networkPath: NetworkPath?
        let connectionVersion: ServerConnection.Version?
        var settings: PlaybackDiagnosticSettings? = nil
        var queueCount: Int? = nil
        var queueIndex: Int? = nil
        var position: Double? = nil
        var duration: Double? = nil
        var waitingReason: PlaybackWaitingReason? = nil
        var lowPowerMode: Bool? = nil
        var thermalState: ProcessInfo.ThermalState? = nil
    }

    enum Event: Sendable, Equatable {
        case context(PlaybackRuntimeDiagnostics)
        case health(AudioEnginePlaybackToken, PlaybackDiagnosticHealth.Finding, seconds: Double)
        case preparation(attempt: UInt64, stage: PreparationStage, seconds: Double)
        case mediaMetadata(duration: Double, format: PlaybackRequestDiagnostics.Format)
        case transition(TransitionDecision, current: AudioEnginePlaybackToken?, next: AudioEnginePlaybackToken?, intended: Bool)
        case streamProbe(item: AudioEnginePlaybackToken?, result: PlaybackStreamProbe.Result)
        case streamProbeStarted(item: AudioEnginePlaybackToken?)
        case musicIntent(MusicIntentEvent)
        case application(ApplicationEvent)
        case connectionChanged(version: ServerConnection.Version, endpoint: ServerEndpoint)
        case connectionRemoved
        case networkPathChanged(NetworkPath)
        case command(PlaybackCommand)
        case pauseRequested(origin: PlaybackCommandOrigin, recoveringAudio: Bool)
        case trackBoundary(ended: AudioEnginePlaybackToken, promoted: AudioEnginePlaybackToken?)
        case boundaryIgnored(AudioEnginePlaybackToken, BoundaryDecision)
        case boundaryPlan(AudioEnginePlaybackToken, PlaybackTransitionPlanner.Snapshot, PlaybackTransitionPlanner.Plan)
        case boundaryFailed(AudioEnginePlaybackToken, AudioEngineFailure)
        case sourcePrepared(SourceKind)
        case cache(CacheEvent)
        case playbackStateChanged(PlaybackStatus)
        case engineStateChanged(EngineStatus)
        case engineSnapshot(AudioEngineDiagnosticSnapshot)
        case streamingEngineSnapshot(StreamingEngineDiagnosticSnapshot)
        case activeItem(AudioEnginePlaybackToken, source: SourceKind?)
        case nowPlayingRequested(AudioEnginePlaybackToken)
        case sourceRequest(AudioEnginePlaybackToken, PlaybackRequestDiagnostics)
        case seekRequested(item: AudioEnginePlaybackToken?, target: Double, position: Double)
        case seekCompleted(item: AudioEnginePlaybackToken?, target: Double, position: Double, succeeded: Bool, stale: Bool)
        case seekBuffer(started: Bool, seconds: Double)
        case serverProbeStarted(request: UInt64)
        case serverProbeCompleted(request: UInt64, seconds: Double, availability: MediaAvailability, failure: PlaybackDiagnosticFailure?)
        case recoveryScheduled(item: AudioEnginePlaybackToken?, path: UInt64, delay: Double, baseline: Double, requireStall: Bool)
        case operationFailed(item: AudioEnginePlaybackToken?, failure: PlaybackDiagnosticFailure)
        case engineFailure(AudioEngineFailure, playbackToken: AudioEnginePlaybackToken)
        case mediaAvailabilityChecked(MediaAvailability, playbackGeneration: UInt64)
        case unavailableTrackSkipped(hasNext: Bool)
        case networkRecovery(NetworkRecoveryEvent)
        case audioSession(AudioSessionEvent)
    }

    enum PreparationStage: String, Sendable { case requested, resolving, resolved, starting, started, abandoned, delayed }
    enum TransitionDecision: String, Sendable {
        case waitingForNativeAdvance, queuedPromoted, crossfadePromoted, coldBoundary, adoptPromoted, manualQueuedAdvance, freshItem
    }

    private struct Entry: Sendable {
        let sequence: Int
        let elapsed: TimeInterval
        var lastElapsed: TimeInterval
        var repetitions: Int = 1
        let event: Event
    }

    private struct State: Sendable {
        var engineName = "not-yet-observed"
        let startedUptime: TimeInterval
        var entries: [Entry]
        var received = 0
        var evicted = 0
        var incidents: [Entry] = []
        var lastActiveSnapshot: Entry?
        var experience = PlaybackExperienceMetrics()
        var homeReadyTimes: [TimeInterval] = []
        var homeCacheLoads = 0
        var completedDownloads = 0
        var failedDownloads = 0
        var context: [String: Entry] = [:]
        var capsules: [Capsule] = []
        var capturedIncidents: [String: TimeInterval] = [:]
    }

    private struct Capsule: Sendable {
        let trigger: Entry
        let context: [Entry]
        var entries: [Entry]
        var remaining: Int = 24
    }

    private let capacity: Int
    private let state: Mutex<State>
    private let sessionID = UUID()
    private let startedAt = Date()
    private let environment: String
    private let archive: PlaybackDiagnosticArchive?
    let networkProbesEnabled: Bool

    init(capacity: Int = 600, persistenceDirectory: URL? = nil, networkProbesEnabled: Bool = false) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.networkProbesEnabled = networkProbesEnabled
        state = Mutex(State(startedUptime: ProcessInfo.processInfo.systemUptime, entries: []))
        environment = "App: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")); OS: \(ProcessInfo.processInfo.operatingSystemVersionString)"
        if let persistenceDirectory {
            archive = PlaybackDiagnosticArchive(directory: persistenceDirectory, sessionID: sessionID)
        } else { archive = nil }
    }

    func record(_ event: Event) {
        let event = Self.redacted(event)
        let now = ProcessInfo.processInfo.systemUptime
        state.withLock { state in
            let elapsed = max(0, now - state.startedUptime)
            state.experience.observe(event, elapsed: elapsed)
            state.received += 1
            let entry = Entry(sequence: state.received, elapsed: elapsed, lastElapsed: elapsed, event: event)
            let contextKey: String? = switch event {
            case .context: "runtime"
            case .networkPathChanged: "network"
            case .connectionChanged, .connectionRemoved: "connection"
            case .sourceRequest(let token, _): "request-\(token.rawValue)"
            case .activeItem: "item"
            case .mediaMetadata: "metadata"
            case .preparation: "preparation"
            case .application(.lifecycle): "lifecycle"
            default: nil
            }
            if let contextKey { state.context[contextKey] = entry }
            let requests = state.context.filter { $0.key.hasPrefix("request-") }.sorted { $0.value.sequence > $1.value.sequence }
            for old in requests.dropFirst(4) { state.context.removeValue(forKey: old.key) }
            for index in state.capsules.indices where state.capsules[index].remaining > 0 {
                state.capsules[index].entries.append(entry)
                state.capsules[index].remaining -= 1
            }
            let isIncident = Self.severity(event) != "INFO"
            let incidentKey = isIncident ? Self.incidentKey(event) : ""
            if isIncident,
               elapsed - (state.capturedIncidents[incidentKey] ?? -1_000) >= 300,
               elapsed - (state.capsules.last?.trigger.elapsed ?? -100) >= 10 {
                state.capturedIncidents[incidentKey] = elapsed
                if state.capturedIncidents.count > 64,
                   let oldest = state.capturedIncidents.min(by: { $0.value < $1.value })?.key {
                    state.capturedIncidents.removeValue(forKey: oldest)
                }
                state.capsules.append(Capsule(trigger: entry,
                    context: state.context.values.sorted { $0.sequence < $1.sequence },
                    entries: Array(state.entries.suffix(24)) + [entry]))
                if state.capsules.count > 6 { state.capsules.removeFirst() }
            }
            switch event {
            case .engineSnapshot(let snapshot) where snapshot.role == .active:
                state.lastActiveSnapshot = entry
                state.engineName = "AVQueuePlayer"
            case .streamingEngineSnapshot:
                state.lastActiveSnapshot = entry
                state.engineName = "AudioStreaming"
            case .command(.stop), .command(.play), .command(.playRadio), .connectionRemoved:
                state.lastActiveSnapshot = nil
            case .activeItem(let token, _):
                if let observation = state.lastActiveSnapshot,
                   case .streamingEngineSnapshot(let snapshot) = observation.event, snapshot.token != token {
                    state.lastActiveSnapshot = nil
                }
                if let observation = state.lastActiveSnapshot,
                   case .engineSnapshot(let snapshot) = observation.event, snapshot.token != token {
                    state.lastActiveSnapshot = nil
                }
            default: break
            }
            if Self.severity(event) != "INFO" {
                if let last = state.incidents.last, last.event == event {
                    state.incidents[state.incidents.count - 1].repetitions += 1
                    state.incidents[state.incidents.count - 1].lastElapsed = elapsed
                } else {
                    state.incidents.append(entry)
                }
                if state.incidents.count > 20 { state.incidents.removeFirst() }
            }
            if let last = state.entries.last, last.event == event {
                state.entries[state.entries.count - 1].repetitions += 1
                state.entries[state.entries.count - 1].lastElapsed = elapsed
            } else {
                state.entries.append(entry)
            }
            if state.entries.count > capacity {
                let removed = state.entries.count - capacity
                state.evicted += state.entries.prefix(removed).reduce(0) { $0 + $1.repetitions }
                state.entries.removeFirst(removed)
            }
        }
        archive?.schedule(urgent: Self.severity(event) != "INFO" || event == .application(.lifecycle(.background))
            || event == .command(.pause) || event == .command(.stop)) { [weak self] in
            self?.archivedSession()
        }
    }

    func flush() { archive?.flush() }

    private static func redacted(_ event: Event) -> Event {
        if case .application(.launchFailed(let domain, let code)) = event {
            let allowed = ["SwiftData", "NSCocoaErrorDomain", "NSURLErrorDomain", "NSPOSIXErrorDomain",
                           "AVFoundationErrorDomain", "NSOSStatusErrorDomain"]
            return .application(.launchFailed(errorDomain: allowed.contains(domain) ? domain : "other", errorCode: code))
        }
        return event
    }

    private func archivedSession() -> PlaybackDiagnosticArchive.Session {
        let value = state.withLock { $0 }
        var rows = value.entries.map(Self.describeEntry)
        var capsules = value.capsules
        let context = ["=== LAST RECORDED CONTEXT ==="] + value.context.values.sorted { $0.sequence < $1.sequence }.map(Self.describeEntry)
            + ["=== LAST ENGINE OBSERVATION ===", value.lastActiveSnapshot.map(Self.describeEntry) ?? "unavailable"]
            + ["=== RECENT INCIDENTS ==="] + value.incidents.map(Self.describeEntry)
        func render() -> String {
            (context + Self.describeCapsules(capsules)
                + ["=== RETAINED TIMELINE ===", "received=\(value.received) evicted-events=\(value.evicted) archived-rows=\(rows.count)"]
                + rows).joined(separator: "\n")
        }
        var text = render()
        // Leave room for JSON escaping without dropping an entire checkpoint at the disk limit.
        while text.utf8.count > 1_200_000 && rows.count > 1 {
            rows.removeFirst(min(50, rows.count - 1))
            text = render()
        }
        while text.utf8.count > 1_200_000 && capsules.count > 1 {
            capsules.removeFirst()
            text = render()
        }
        return .init(id: sessionID, startedAt: startedAt,
                     environment: "\(environment); engine=\(value.engineName)", text: text)
    }

    private static func incidentKey(_ event: Event) -> String {
        switch event {
        case .engineSnapshot(let snapshot): "engine-\(snapshot.token.rawValue)-\(snapshot.trigger.rawValue)"
        case .health(let token, let finding, _): "health-\(token.rawValue)-\(finding.rawValue)"
        default: describe(event)
        }
    }

    private static func describeCapsules(_ capsules: [Capsule]) -> [String] {
        var lines = ["", "=== AUTOMATIC INCIDENT CAPTURES (up to 6) ===",
                     "Each capture retains context + up to 24 events before/after a warning. Observations are not diagnoses."]
        if capsules.isEmpty { lines.append("No incident captured.") }
        for capsule in capsules {
            lines += ["", "Incident triggered by #\(capsule.trigger.sequence); following events still pending=\(capsule.remaining)", "Context at detection:"]
            lines += capsule.context.map(describeEntry)
            lines.append("Before / during / after:")
            lines += capsule.entries.map(describeEntry)
        }
        return lines
    }

    func recordProgress(_ position: TimeInterval) {
        state.withLock { state in
            state.experience.observeProgress(position, elapsed: max(0, ProcessInfo.processInfo.systemUptime - state.startedUptime))
        }
    }

    func recordHomeContentReady(after duration: TimeInterval, fromCache: Bool) {
        guard duration.isFinite, duration >= 0 else { return }
        state.withLock {
            $0.homeReadyTimes.append(duration)
            if $0.homeReadyTimes.count > 100 { $0.homeReadyTimes.removeFirst() }
            if fromCache { $0.homeCacheLoads += 1 }
        }
    }

    func recordDownloadOutcome(succeeded: Bool) {
        state.withLock {
            if succeeded { $0.completedDownloads += 1 }
            else { $0.failedDownloads += 1 }
        }
    }

    func makeReport(context: ReportContext) -> String {
        let value = state.withLock { $0 }
        let now = max(0, ProcessInfo.processInfo.systemUptime - value.startedUptime)
        let times = value.homeReadyTimes.sorted()
        let median = times.isEmpty ? "unavailable" : String(format: "%.3fs", times[(times.count - 1) / 2])
        let waiting = switch context.waitingReason {
        case .loading: "loading"
        case .buffering: "buffering"
        case .reconnecting: "reconnecting"
        case nil: "none"
        }
        let thermal = switch context.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        default: "unknown"
        }
        var lines = [
            "Minidisc Playback Diagnostics — report v3",
            "Generated: \(Date().formatted(.iso8601))",
            "Session: \(sessionID.uuidString) started=\(startedAt.formatted(.iso8601)); engine=\(value.engineName)",
            "Autonomous HTTP probes enabled=\(networkProbesEnabled)",
            "",
            "=== CURRENT CONTEXT ===",
            "App: \(context.appVersion) (\(context.appBuild))",
            "OS: \(context.operatingSystem)",
            "Device: low-power=\(context.lowPowerMode.map(String.init) ?? "unknown") thermal=\(thermal)",
            "Playback: \(context.playbackStatus.rawValue), available=\(context.isPlaybackAvailable), visible-wait=\(waiting)",
            "Queue: count=\(context.queueCount.map(String.init) ?? "unknown") index=\(context.queueIndex.map(String.init) ?? "unknown") (zero-based)",
            "Position: \(Self.seconds(context.position)) / \(Self.seconds(context.duration)) seconds",
            "Network: \(context.networkPath.map(Self.describe) ?? "unavailable")",
            "Connection: \(context.connectionVersion?.description ?? "none")",
            "",
            "=== SETTINGS AT EXPORT ===",
            context.settings?.description ?? "unavailable",
            "Settings may have changed since the incident; SOURCE events describe each actual request.",
            "",
            "=== LAST ACTIVE ENGINE OBSERVATION ==="
        ]
        if let observation = value.lastActiveSnapshot {
            lines.append("Observed \(Self.seconds(now - observation.elapsed)) seconds before export; this is a recorded snapshot, not a fresh probe.")
            lines.append(Self.describe(observation.event))
            if case .engineSnapshot(let snapshot) = observation.event,
               let request = value.entries.last(where: {
                   if case .sourceRequest(let token, _) = $0.event { return token == snapshot.token }
                   return false
               }) {
                lines.append(Self.describe(request.event))
            }
        } else {
            lines.append("No active engine observation available for the latest playback request.")
        }
        lines += ["", "=== RECENT INCIDENTS (up to 20, retained separately) ==="]
        lines += value.incidents.isEmpty ? ["No warning/error events recorded."] : value.incidents.map(Self.describeEntry)
        lines += Self.describeCapsules(value.capsules)
        lines += [
            "", "=== SESSION METRICS ===",
            value.experience.report,
            "Continuity (this launch): home-data-ready samples=\(times.count) p50=\(median) cache-loads=\(value.homeCacheLoads); download-attempts completed=\(value.completedDownloads) failed=\(value.failedDownloads). Home timing excludes rendering.",
            "", "=== HOW TO READ ===",
            "Times are monotonic seconds since this diagnostic session began. Item numbers identify individual engine loads, not songs. Probe numbers identify getSong metadata requests, not audio transfers.",
            "Now Playing is a client announcement, not confirmation of sound. Media-clock progress does not prove that the AirPlay receiver produced sound.",
            "Requested format is not the decoded format. serverDefault means no format override; it does not guarantee an untranscoded response.",
            "Access counters belong to the latest AVFoundation access-log event, not the entire session. Unavailable counters are not zero. A zero preferred buffer/peak bitrate lets AVFoundation choose.",
            "Samples are recorded every 5s while waiting/paused with play intent, otherwise every 15s. Lifecycle events are recorded immediately. Consecutive identical events are grouped.",
            "Automatic health observations flag a motionless clock after 10s, or a pending native hand-off after 3s. Sampling gaps reset detection; suspension is not diagnosed as a stall.",
            "HTTP checks are separate, bounded diagnostic requests, not measurements of AVPlayer's own connection. They run only during recovery, at most once per five minutes.",
            "Privacy: song metadata, full URLs, credentials, header names/values, response bodies and route names are excluded.",
            "", "=== TIMELINE (oldest to newest) ===",
            "Retention: received=\(value.received) rows=\(value.entries.count)/\(capacity) evicted-events=\(value.evicted)"
        ]
        lines += value.entries.isEmpty ? ["(no events recorded)"] : value.entries.map(Self.describeEntry)
        if let archive {
            let history = archive.previousSessions()
            lines += ["", "=== PREVIOUS LAUNCHES ===",
                      "Local retention: current + 3 previous launches, up to 7 days, at most 2 MiB per launch; excluded from backup. Checkpoints every 30s and on incidents; abrupt termination can lose recent events.",
                      "Archive write-failed=\(history.writeFailed)"]
            for session in history.sessions {
                lines += ["", "Session: \(session.id.uuidString) started=\(session.startedAt.formatted(.iso8601))", session.environment, session.text]
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func seconds(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "unknown" }
        return String(format: "%.2f", value)
    }

    private static func describeEntry(_ entry: Entry) -> String {
        let repetitions = entry.repetitions > 1
            ? " [repeated \(entry.repetitions)x; last +\(seconds(entry.lastElapsed))s]" : ""
        return String(format: "#%04d +%09.3fs [%@] [%@] %@%@", entry.sequence, entry.elapsed,
                      severity(entry.event), category(entry.event), describe(entry.event), repetitions)
    }

    private static func severity(_ event: Event) -> String {
        switch event {
        case .preparation(_, .delayed, _): "WARN"
        case .health(_, let finding, _):
            finding == .progressRecovered || finding == .samplingGap ? "INFO" : "WARN"
        case .streamProbe(_, let result): result.isUnexpected ? "WARN" : "INFO"
        case .operationFailed(_, let failure): failure.kind == .cancelled ? "INFO" : "ERROR"
        case .engineFailure, .boundaryFailed, .application(.launchFailed),
             .playbackStateChanged(.error), .engineStateChanged(.error), .networkRecovery(.retryBudgetExhausted), .audioSession(.recoveryExhausted):
            "ERROR"
        case .engineSnapshot(let snapshot):
            snapshot.trigger == .errorLog || snapshot.trigger == .failedToEnd ? "ERROR"
                : (snapshot.trigger == .stalled || snapshot.trigger == .watchdogEnd ? "WARN" : "INFO")
        case .serverProbeCompleted(_, _, _, let failure): failure == nil ? "INFO" : "WARN"
        case .seekCompleted(_, _, _, let succeeded, let stale): succeeded || stale ? "INFO" : "WARN"
        case .cache(.failed), .networkRecovery(.sourceRefreshFailed), .networkRecovery(.progressStalled),
             .audioSession(.mediaServicesReset), .audioSession(.mediaServicesLost), .audioSession(.resetReceived),
             .audioSession(.recoveryActivationFailed), .audioSession(.interruptionBegan): "WARN"
        default: "INFO"
        }
    }

    private static func category(_ event: Event) -> String {
        switch event {
        case .context: "CONTEXT"
        case .health: "HEALTH"
        case .preparation: "PREPARATION"
        case .mediaMetadata: "SOURCE"
        case .transition: "QUEUE"
        case .streamProbe, .streamProbeStarted: "HTTP-PROBE"
        case .engineSnapshot, .streamingEngineSnapshot, .engineFailure, .engineStateChanged: "ENGINE"
        case .sourceRequest, .sourcePrepared, .activeItem: "SOURCE"
        case .seekRequested, .seekCompleted, .seekBuffer: "SEEK"
        case .serverProbeStarted, .serverProbeCompleted, .nowPlayingRequested: "SERVER"
        case .networkRecovery, .recoveryScheduled: "RECOVERY"
        case .networkPathChanged, .connectionChanged, .connectionRemoved: "NETWORK"
        case .audioSession: "AUDIO"
        case .cache: "CACHE"
        case .trackBoundary, .boundaryIgnored, .boundaryPlan, .boundaryFailed: "QUEUE"
        case .musicIntent: "SIRI"
        case .application: "APP"
        default: "PLAYBACK"
        }
    }

    private static func describe(_ event: Event) -> String {
        switch event {
        case .context(let snapshot): snapshot.description
        case .health(let token, let finding, let duration):
            "automatic-observation item=\(token.rawValue) finding=\(finding.rawValue) elapsed=\(seconds(duration))s"
        case .preparation(let attempt, let stage, let duration):
            "playback preparation=\(attempt) stage=\(stage.rawValue) elapsed=\(seconds(duration))s"
        case .mediaMetadata(let duration, let format):
            "library-metadata duration=\(seconds(duration)) format-hint=\(format.rawValue) (not the decoded stream format)"
        case .transition(let decision, let current, let next, let intended):
            "engine transition=\(decision.rawValue) current=\(current.map { String($0.rawValue) } ?? "none") next=\(next.map { String($0.rawValue) } ?? "none") intent-play=\(intended)"
        case .streamProbeStarted(let token):
            "stream-check started item=\(token.map { String($0.rawValue) } ?? "none") range=bytes-0-1023 read-limit=1024 timeout=8s"
        case .streamProbe(let token, let result):
            "stream-check completed item=\(token.map { String($0.rawValue) } ?? "none") \(result.description)"
        case .musicIntent(let intent):
            switch intent {
            case .siriKitResolution: "music-intent sirikit-resolve"
            case .siriKitPlayback: "music-intent sirikit-play"
            case .siriKitSearch: "music-intent sirikit-search"
            case .unrecognizedMediaIdentifier: "music-intent unrecognized-identifier searching-by-name"
            case .audioSearch: "music-intent audio-search"
            case .audioPlayback: "music-intent audio-play"
            case .searchStarted: "music-intent search-started"
            case .searchCompleted(let count): "music-intent search-completed count=\(count)"
            case .selectionPlayback: "music-intent selection-play"
            }
        case .application(.launchStarted(let attempt)):
            "app launch-started attempt=\(attempt)"
        case .application(.servicesReady):
            "app services-ready"
        case .application(.lifecycle(let phase)):
            "app lifecycle=\(phase.rawValue)"
        case .application(.launchFailed(let domain, let code)):
            "app launch-failed error-domain=\(domain) error-code=\(code)"
        case .connectionChanged(let version, let endpoint):
            "connection changed \(version) tls=\(endpoint.usesTLS) port=\(endpoint.port.map(String.init) ?? "default") host=\(endpoint.hostKind.rawValue)#\(endpoint.hostFingerprint) custom-header-count=\(endpoint.customHeaderCount.map(String.init) ?? "unknown")"
        case .connectionRemoved:
            "connection removed"
        case .networkPathChanged(let path):
            "network path-changed \(describe(path))"
        case .command(let command):
            "playback command=\(describe(command))"
        case .pauseRequested(let origin, let recoveringAudio):
            "playback pause-origin=\(origin.rawValue) audio-recovery=\(recoveringAudio)"
        case .trackBoundary(let ended, let promoted):
            "playback track-ended item=\(ended.rawValue) promoted-item=\(promoted.map { String($0.rawValue) } ?? "none")"
        case .boundaryIgnored(let token, let decision):
            "playback track-end-ignored item=\(token.rawValue) reason=\(decision.rawValue)"
        case .boundaryPlan(let token, let snapshot, let plan):
            "playback track-end-plan item=\(token.rawValue) queue-count=\(snapshot.queueCount) index=\(snapshot.currentIndex) action=\(describe(plan))"
        case .boundaryFailed(let token, let failure):
            "playback track-end-failed item=\(token.rawValue) codes=\(failure.diagnosticDescription) meaning=\(failure.diagnosticMeaning)"
        case .sourcePrepared(let source):
            "playback source=\(source.rawValue)"
        case .cache(let event):
            "audio-cache \(describe(event))"
        case .playbackStateChanged(let status):
            "playback state=\(status.rawValue)"
        case .engineStateChanged(let status):
            "engine state=\(status.rawValue)"
        case .engineSnapshot(let snapshot):
            snapshot.description
        case .streamingEngineSnapshot(let snapshot):
            snapshot.description
        case .activeItem(let token, let source):
            "playback active-item=\(token.rawValue) source=\(source?.rawValue ?? "unknown")"
        case .nowPlayingRequested(let token):
            "server now-playing-requested item=\(token.rawValue) progress-confirmation=not-required"
        case .sourceRequest(let token, let request):
            "request item=\(token.rawValue) \(request.description)"
        case .seekRequested(let token, let target, let position):
            "seek-requested item=\(token.map { String($0.rawValue) } ?? "none") target=\(seconds(target))s before=\(seconds(position))s"
        case .seekCompleted(let token, let target, let position, let succeeded, let stale):
            "seek-completed item=\(token.map { String($0.rawValue) } ?? "none") target=\(seconds(target))s landed=\(seconds(position))s success=\(succeeded) stale=\(stale)"
        case .seekBuffer(let started, let duration):
            "transcode-seek-buffer \(started ? "started" : "ready") elapsed=\(seconds(duration))s"
        case .serverProbeStarted(let request):
            "getSong request=\(request) started (metadata only)"
        case .serverProbeCompleted(let request, let duration, let availability, let failure):
            "getSong request=\(request) completed elapsed=\(seconds(duration))s availability=\(availability.rawValue) result=\(failure?.description ?? "success")"
        case .recoveryScheduled(let token, let path, let delay, let baseline, let requireStall):
            "probe-scheduled item=\(token.map { String($0.rawValue) } ?? "none") path=\(path) delay=\(seconds(delay))s baseline=\(seconds(baseline))s require-stall=\(requireStall)"
        case .operationFailed(let token, let failure):
            "operation-failed item=\(token.map { String($0.rawValue) } ?? "none") \(failure.description)"
        case .engineFailure(let failure, let token):
            "engine failure item=\(token.rawValue) codes=\(failure.diagnosticDescription) meaning=\(failure.diagnosticMeaning)"
        case .mediaAvailabilityChecked(let availability, let generation):
            "playback media-availability=\(availability.rawValue) generation=\(generation)"
        case .unavailableTrackSkipped(let hasNext):
            "playback unavailable-track has-next=\(hasNext)"
        case .networkRecovery(let recovery):
            "network-recovery \(describe(recovery))"
        case .audioSession(let audioSession):
            "audio-session \(describe(audioSession))"
        }
    }

    private static func describe(_ path: NetworkPath) -> String {
        var interfaces: [String] = []
        if path.interfaces.contains(.wifi) { interfaces.append("wifi") }
        if path.interfaces.contains(.cellular) { interfaces.append("cellular") }
        if path.interfaces.contains(.wiredEthernet) { interfaces.append("ethernet") }
        if path.interfaces.contains(.other) { interfaces.append("other") }
        return "generation=\(path.generation) online=\(path.isOnline) expensive=\(path.isExpensive) constrained=\(path.isConstrained) dns=\(path.supportsDNS) ipv4=\(path.supportsIPv4) ipv6=\(path.supportsIPv6) interfaces=\(interfaces.isEmpty ? "none" : interfaces.joined(separator: "+"))"
    }

    private static func describe(_ event: CacheEvent) -> String {
        switch event {
        case .scheduled(let format, let allowsCellular):
            "scheduled format=\(format.rawValue) cellular=\(allowsCellular)"
        case .started: "download-started"
        case .stored: "stored"
        case .alreadyLocal: "already-local"
        case .skippedCellular: "skipped-cellular"
        case .cancelled: "cancelled"
        case .failed(let code): "failed error-code=\(code)"
        }
    }

    private static func describe(_ plan: PlaybackTransitionPlanner.Plan) -> String {
        switch plan {
        case .playQueueItem(let index, _): "play-index-\(index)"
        case .restartCurrent: "restart-current"
        case .repeatCurrent: "repeat-current"
        case .stopAtEnd: "stop-at-end"
        case .restartQueue: "restart-queue"
        case .resumeCurrent: "resume-current"
        }
    }

    private static func describe(_ command: PlaybackCommand) -> String {
        switch command {
        case .play(let queueCount, let startIndex):
            "play queue-count=\(queueCount) start-index=\(startIndex)"
        case .playRadio: "play-radio"
        case .pause: "pause"
        case .resume: "resume"
        case .stop: "stop"
        case .next: "next"
        case .previous: "previous"
        }
    }

    private static func describe(_ recovery: NetworkRecoveryEvent) -> String {
        switch recovery {
        case .marked(let generation, let automatic):
            "marked path=\(generation) automatic=\(automatic)"
        case .playbackReasserted(let generation):
            "playback-reasserted path=\(generation)"
        case .attemptStarted(let number, let generation):
            "attempt-started number=\(number) path=\(generation)"
        case .sourceRefreshFailed(let number, let generation):
            "source-refresh-failed number=\(number) path=\(generation)"
        case .itemRebuilt(let number, let generation):
            "item-rebuilt number=\(number) path=\(generation)"
        case .progressValidated(let generation):
            "progress-validated path=\(generation)"
        case .progressStalled(let generation):
            "progress-stalled path=\(generation)"
        case .retryBudgetExhausted(let generation):
            "retry-budget-exhausted path=\(generation)"
        }
    }

    private static func describe(_ event: AudioSessionEvent) -> String {
        switch event {
        case .interruptionBegan(let disconnected):
            "interruption-began route-disconnected=\(disconnected)"
        case .interruptionEnded(let shouldResume):
            "interruption-ended should-resume=\(shouldResume)"
        case .interruptionSupersededByPlayback:
            "interruption-superseded-by-playback activation-confirmed=true"
        case .routeChanged(let reasonCode, let outputs):
            "route-changed reason-code=\(reasonCode) outputs=\(outputs.sorted().map(\.rawValue).joined(separator: "+"))"
        case .systemPauseArmed(let requiresPersonalRoute):
            "system-pause-armed requires-personal-route=\(requiresPersonalRoute)"
        case .systemResumeAttempted:
            "system-resume-attempted"
        case .mediaServicesReset:
            "media-services-reset players-recreated=true"
        case .mediaServicesLost:
            "media-services-lost notification-received=true"
        case .resetReceived(let item):
            "media-services-reset trigger=\(item == nil ? "system-notification" : "item-error") item=\(item.map { String($0.rawValue) } ?? "none")"
        case .transitionModeChanged(let airPlay):
            "airplay=\(airPlay) crossfade-policy=\(airPlay ? "disabled" : "per-transition")"
        case .transitionPrepared(let crossfade):
            "transition-prepared=\(crossfade ? "crossfade" : "native-queue")"
        case .recoveryAttemptStarted(let number):
            "audio-recovery attempt-started number=\(number)"
        case .recoveryActivationFailed(let code):
            "audio-recovery activation-failed code=\(code)"
        case .recoveryWaitingForRoute:
            "audio-recovery waiting-for-route"
        case .recoveryProgressValidated:
            "audio-recovery progress-validated"
        case .recoveryExhausted:
            "audio-recovery exhausted"
        case .recoveryInterrupted:
            "audio-recovery interrupted"
        }
    }
}
