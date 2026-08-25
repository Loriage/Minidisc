import CryptoKit
import Foundation
import Synchronization

/// A bounded, process-local timeline for playback support reports.
///
/// Events accept only redacted domain values: song metadata, raw URLs, credentials, headers and
/// audio-route names cannot enter the buffer by construction.
nonisolated final class PlaybackDiagnostics: Sendable {
    enum ApplicationEvent: Sendable, Equatable {
        case launchStarted(attempt: Int)
        case servicesReady
        case launchFailed(errorDomain: String, errorCode: Int)
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
        case download
        case cache
        case remoteStream
        case liveStream
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
        case routeChanged(reasonCode: UInt, outputs: [AudioOutputKind])
        case systemPauseArmed(requiresPersonalRoute: Bool)
        case systemResumeAttempted
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
    }

    enum Event: Sendable, Equatable {
        case application(ApplicationEvent)
        case connectionChanged(version: ServerConnection.Version, endpoint: ServerEndpoint)
        case connectionRemoved
        case networkPathChanged(NetworkPath)
        case command(PlaybackCommand)
        case sourcePrepared(SourceKind)
        case playbackStateChanged(PlaybackStatus)
        case engineStateChanged(EngineStatus)
        case networkRecovery(NetworkRecoveryEvent)
        case audioSession(AudioSessionEvent)
    }

    private struct Entry: Sendable {
        let elapsed: TimeInterval
        let event: Event
    }

    private struct State: Sendable {
        let startedAt: Date
        var entries: [Entry]
    }

    private let capacity: Int
    private let state: Mutex<State>

    init(capacity: Int = 200) {
        precondition(capacity > 0)
        self.capacity = capacity
        state = Mutex(State(startedAt: Date(), entries: []))
    }

    func record(_ event: Event) {
        let now = Date()
        state.withLock { state in
            state.entries.append(
                Entry(elapsed: max(0, now.timeIntervalSince(state.startedAt)), event: event)
            )
            if state.entries.count > capacity {
                state.entries.removeFirst(state.entries.count - capacity)
            }
        }
    }

    func makeReport(context: ReportContext) -> String {
        let entries = state.withLock { $0.entries }
        var lines = [
            "Minidisc Playback Diagnostics",
            "Generated: \(Date().formatted(.iso8601))",
            "App: \(context.appVersion) (\(context.appBuild))",
            "OS: \(context.operatingSystem)",
            "Playback: \(context.playbackStatus.rawValue), available=\(context.isPlaybackAvailable)",
            "Network: \(context.networkPath.map(Self.describe) ?? "unavailable")",
            "Connection: \(context.connectionVersion?.description ?? "none")",
            "Privacy: song metadata, full URLs, credentials, header names/values and route names are excluded.",
            "",
            "Timeline (oldest to newest):"
        ]

        if entries.isEmpty {
            lines.append("(no events recorded)")
        } else {
            lines.append(contentsOf: entries.map { entry in
                String(format: "+%.3fs %@", entry.elapsed, Self.describe(entry.event))
            })
        }
        return lines.joined(separator: "\n")
    }

    private static func describe(_ event: Event) -> String {
        switch event {
        case .application(.launchStarted(let attempt)):
            "app launch-started attempt=\(attempt)"
        case .application(.servicesReady):
            "app services-ready"
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
        case .sourcePrepared(let source):
            "playback source=\(source.rawValue)"
        case .playbackStateChanged(let status):
            "playback state=\(status.rawValue)"
        case .engineStateChanged(let status):
            "engine state=\(status.rawValue)"
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
        case .routeChanged(let reasonCode, let outputs):
            "route-changed reason-code=\(reasonCode) outputs=\(outputs.sorted().map(\.rawValue).joined(separator: "+"))"
        case .systemPauseArmed(let requiresPersonalRoute):
            "system-pause-armed requires-personal-route=\(requiresPersonalRoute)"
        case .systemResumeAttempted:
            "system-resume-attempted"
        }
    }
}
