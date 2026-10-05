import AVFoundation
import Foundation
import Testing
import SwiftSonic
@testable import Minidisc

@Suite("Playback diagnostics")
struct PlaybackDiagnosticsTests {
    private func report(_ diagnostics: PlaybackDiagnostics) -> String {
        diagnostics.makeReport(context: .init(
            appVersion: "test", appBuild: "0", operatingSystem: "test", playbackStatus: .loading,
            isPlaybackAvailable: true, networkPath: nil, connectionVersion: nil
        ))
    }

    @Test func reportSeparatesCurrentSettingsFromEngineObservations() {
        let output = PlaybackDiagnostics().makeReport(context: .init(
            appVersion: "test", appBuild: "0", operatingSystem: "test", playbackStatus: .playing,
            isPlaybackAvailable: true, networkPath: nil, connectionVersion: nil,
            settings: .init(wifiQuality: .original, cellularQuality: .mp3_192, selectedQuality: .mp3_192,
                offlineMode: false, cacheFormat: .matchStream, cacheOverCellular: false,
                cacheCapacityMB: 512, offlineFavorites: true,
                crossfade: .init(duration: 0, disableForGapless: true),
                replayGain: .init(enabled: false, mode: .track, preAmp: 0, preventClipping: true)),
            queueCount: 12, queueIndex: 2, position: 0, duration: 180, waitingReason: .buffering,
            lowPowerMode: true, thermalState: .nominal
        ))
        #expect(output.contains("visible-wait=buffering"))
        #expect(output.contains("wifi=original cellular=mp3_192 selected-now=mp3_192"))
        #expect(output.contains("count=12 index=2 (zero-based)"))
        #expect(output.contains("Device: low-power=true thermal=nominal"))
        #expect(output.contains("No active engine observation available"))
    }

    @Test func requestParametersAreAllowlistedAndDoNotPromiseOriginalAudio() throws {
        let url = try #require(URL(string: "https://user:password@secret.example/private/SONG?u=PRIVATE_USER&t=PRIVATE_TOKEN&format=mp3&maxBitRate=192&estimateContentLength=true"))
        let request = PlaybackRequestDiagnostics(url: url, headerCount: 2)
        #expect(request.requestedFormat == .mp3)
        #expect(request.maxBitRate == 192)
        #expect(request.estimateContentLength == true)
        let diagnostics = PlaybackDiagnostics()
        diagnostics.record(.sourceRequest(.init(rawValue: 7), request))
        let output = report(diagnostics)
        #expect(output.contains("requested-format=mp3 max-kbps=192"))
        for secret in ["password", "secret.example", "SONG", "PRIVATE_USER", "PRIVATE_TOKEN"] {
            #expect(!output.contains(secret))
        }
        let original = PlaybackRequestDiagnostics(url: URL(string: "https://secret.example/rest/stream?id=SECRET")!, headerCount: 0)
        #expect(original.requestedFormat == .serverDefault)
        #expect(original.maxBitRate == nil)
        let hostile = PlaybackRequestDiagnostics(url: URL(string: "https://secret.example/?format=SECRET&maxBitRate=SECRET&timeOffset=nan&estimateContentLength=SECRET")!, headerCount: 0)
        #expect(hostile.requestedFormat == .other)
        #expect(hostile.timeOffset == nil)
        #expect(!hostile.description.contains("SECRET"))
    }

    @Test func serverFailuresKeepStatusButExcludePayloadsAndHosts() {
        let diagnostics = PlaybackDiagnostics()
        diagnostics.record(.serverProbeCompleted(request: 1, seconds: 2.5, availability: .unknown,
            failure: PlaybackDiagnosticFailure(SwiftSonicError.httpError(statusCode: 503, endpoint: "PRIVATE_ENDPOINT", serverHost: "PRIVATE_HOST"))))
        diagnostics.record(.operationFailed(item: .init(rawValue: 9), failure: PlaybackDiagnosticFailure(
            SwiftSonicError.insecureRedirect(from: URL(string: "https://PRIVATE_HOST/PRIVATE_TOKEN")!, to: URL(string: "https://PRIVATE_DESTINATION")!))))
        let output = report(diagnostics)
        #expect(output.contains("getSong request=1 completed elapsed=2.50s"))
        #expect(output.contains("kind=http status=503"))
        #expect(output.contains("kind=redirectBlocked"))
        #expect(!output.contains("PRIVATE_"))
        let denied = PlaybackDiagnosticFailure(MinidiscError.connectionFailed(underlying: URLError(.dataNotAllowed)))
        #expect(denied.description.contains("cellular-data-not-allowed"))
        #expect(PlaybackDiagnosticFailure(MinidiscError.timeout).kind == .timeout)
    }

    @Test func noisyEventsAreGroupedAndFailuresSurviveTimelineEviction() {
        let diagnostics = PlaybackDiagnostics(capacity: 2)
        diagnostics.record(.engineFailure(AudioEngineFailure(error: URLError(.timedOut)), playbackToken: .init(rawValue: 4)))
        for _ in 0..<10 { diagnostics.record(.engineStateChanged(.buffering)) }
        diagnostics.record(.engineStateChanged(.playing))
        let output = report(diagnostics)
        #expect(output.contains("repeated 10x"))
        #expect(output.contains("received=12 rows=2/2 evicted-events=1"))
        #expect(output.contains("[ERROR] [ENGINE] engine failure item=4"))
        #expect(output.contains("meaning=request-timeout"))
        let timeline = output.components(separatedBy: "=== TIMELINE").last ?? ""
        #expect(!timeline.contains("engine failure"))
    }

    @Test func exportedSummaryDoesNotPresentThePreviousTrackAsCurrent() {
        let diagnostics = PlaybackDiagnostics()
        let item = AVPlayerItem(url: URL(fileURLWithPath: "/tmp/private-song.flac"))
        diagnostics.record(.engineSnapshot(AudioEngineDiagnosticSnapshot(
            trigger: .sample, token: .init(rawValue: 1), role: .active, player: AVQueuePlayer(), item: item,
            intendedPlayback: true, airPlay: false, replayGainTap: false
        )))
        #expect(report(diagnostics).contains("Observed"))
        diagnostics.record(.activeItem(.init(rawValue: 2), source: .remoteStream))
        #expect(report(diagnostics).contains("No active engine observation available"))
    }

    @Test func bufferedDurationDoesNotCountDataBeyondAGap() {
        func range(_ start: Double, _ duration: Double) -> CMTimeRange {
            CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                        duration: CMTime(seconds: duration, preferredTimescale: 600))
        }
        let ranges = [range(20, 10), range(8, 4), range(0, 10), range(12, 3)]
        #expect(AudioEngineDiagnosticSnapshot.bufferedSeconds(aheadOf: 5, ranges: ranges) == 10)
        #expect(AudioEngineDiagnosticSnapshot.bufferedSeconds(aheadOf: 17, ranges: ranges) == 0)
        #expect(AudioEngineDiagnosticSnapshot.bufferedSeconds(aheadOf: 22, ranges: ranges) == 8)
        #expect(AudioEngineDiagnosticSnapshot.bufferedSeconds(aheadOf: .nan, ranges: ranges) == 0)
    }

    @Test func engineSnapshotExcludesAssetURLsAndUnknownWaitingReasons() {
        let secret = "PRIVATE_TOKEN_AND_SONG"
        let item = AVPlayerItem(url: URL(string: "https://secret.example/\(secret)?token=\(secret)")!)
        let snapshot = AudioEngineDiagnosticSnapshot(
            trigger: .stalled, token: .init(rawValue: 42), role: .queued,
            player: AVQueuePlayer(), item: item, intendedPlayback: true,
            airPlay: true, replayGainTap: false
        )
        let diagnostics = PlaybackDiagnostics()
        diagnostics.record(.engineSnapshot(snapshot))
        diagnostics.record(.activeItem(.init(rawValue: 42), source: .remoteStream))
        diagnostics.record(.nowPlayingRequested(.init(rawValue: 42)))
        let report = diagnostics.makeReport(context: .init(
            appVersion: "test", appBuild: "0", operatingSystem: "test", playbackStatus: .loading,
            isPlaybackAvailable: true, networkPath: nil, connectionVersion: nil
        ))
        #expect(report.contains("trigger=stalled item=42 role=queued"))
        #expect(report.contains("airplay=true"))
        #expect(report.contains("duration=unknown"))
        #expect(report.contains("access={unavailable}"))
        #expect(report.contains("active-item=42 source=remoteStream"))
        #expect(report.contains("now-playing-requested item=42"))
        #expect(!report.contains(secret))
        #expect(!report.contains("secret.example"))
        #expect(AudioEngineDiagnosticSnapshot.WaitingReason(.init(rawValue: secret)) == .other)
        #expect(AudioEngineDiagnosticSnapshot.WaitingReason(.toMinimizeStalls) == .minimizeStalls)
    }

    @Test func engineFailureKeepsCodesWithoutErrorPayloads() {
        let secret = "PRIVATE_TOKEN_AND_SONG"
        let error = NSError(domain: "AVFoundationErrorDomain", code: -11800, userInfo: [
            NSLocalizedDescriptionKey: secret,
            NSUnderlyingErrorKey: NSError(domain: NSURLErrorDomain, code: -1008, userInfo: [
                NSURLErrorFailingURLErrorKey: URL(string: "https://example.com/\(secret)")!
            ])
        ])
        let failure = AudioEngineFailure(error: error, logCode: .init(domain: secret, value: 404))
        let diagnostics = PlaybackDiagnostics()
        diagnostics.record(.engineFailure(failure, playbackToken: .init(rawValue: 3)))
        let report = diagnostics.makeReport(context: .init(
            appVersion: "test", appBuild: "0", operatingSystem: "test", playbackStatus: .error,
            isPlaybackAvailable: true, networkPath: nil, connectionVersion: nil
        ))
        #expect(report.contains("avFoundation:-11800,url:-1008,other:404"))
        #expect(report.contains("item=3"))
        #expect(!report.contains(secret))
        #expect(!report.contains("example.com"))
    }

    @Test func reportRedactsNetworkAndServerDetails() throws {
        let diagnostics = PlaybackDiagnostics(capacity: 10)
        let endpointURL = try #require(
            URL(string: "https://secret.music.example:8443/private/path?token=do-not-share")
        )
        let version = ServerConnection.Version(serverID: UUID(), revision: 4)
        diagnostics.record(
            .connectionChanged(
                version: version,
                endpoint: PlaybackDiagnostics.ServerEndpoint(
                    url: endpointURL,
                    customHeaderCount: 2
                )
            )
        )
        let path = NetworkPathEvent(
            generation: 7,
            descriptor: NetworkPathDescriptor(
                isOnline: true,
                isExpensive: false,
                isConstrained: false,
                supportsDNS: true,
                supportsIPv4: true,
                supportsIPv6: true,
                interfaces: [.wifi],
                gateways: ["192.168.1.1"]
            )
        )
        diagnostics.record(.networkPathChanged(PlaybackDiagnostics.NetworkPath(path)))
        diagnostics.recordHomeContentReady(after: 0.25, fromCache: true)
        diagnostics.recordDownloadOutcome(succeeded: false)

        let report = diagnostics.makeReport(
            context: PlaybackDiagnostics.ReportContext(
                appVersion: "26.8.2",
                appBuild: "1",
                operatingSystem: "iOS",
                playbackStatus: .playing,
                isPlaybackAvailable: true,
                networkPath: PlaybackDiagnostics.NetworkPath(path),
                connectionVersion: version
            )
        )

        #expect(!report.contains("secret.music.example"))
        #expect(!report.contains("private/path"))
        #expect(!report.contains("do-not-share"))
        #expect(!report.contains("192.168.1.1"))
        #expect(!report.contains(version.serverID.uuidString))
        #expect(report.contains("custom-header-count=2"))
        #expect(report.contains("interfaces=wifi"))
        #expect(report.contains("home-data-ready samples=1 p50=0.250s cache-loads=1"))
        #expect(report.contains("download-attempts completed=0 failed=1"))
    }

    @Test func bufferKeepsOnlyNewestEvents() {
        let diagnostics = PlaybackDiagnostics(capacity: 2)
        diagnostics.record(.application(.launchStarted(attempt: 1)))
        diagnostics.record(.application(.launchStarted(attempt: 2)))
        diagnostics.record(.application(.launchStarted(attempt: 3)))

        let path = PlaybackDiagnostics.NetworkPath(.initial)
        let report = diagnostics.makeReport(
            context: PlaybackDiagnostics.ReportContext(
                appVersion: "1",
                appBuild: "1",
                operatingSystem: "iOS",
                playbackStatus: .idle,
                isPlaybackAvailable: false,
                networkPath: path,
                connectionVersion: nil
            )
        )

        #expect(!report.contains("attempt=1"))
        #expect(report.contains("attempt=2"))
        #expect(report.contains("attempt=3"))
    }

    @Test func launchFailureReportWorksBeforeNetworkAndServicesExist() {
        let diagnostics = PlaybackDiagnostics(capacity: 4)
        diagnostics.record(
            .application(.launchFailed(errorDomain: "SwiftData", errorCode: 134060))
        )

        let report = diagnostics.makeReport(
            context: PlaybackDiagnostics.ReportContext(
                appVersion: "26.8.3",
                appBuild: "25",
                operatingSystem: "iOS",
                playbackStatus: .idle,
                isPlaybackAvailable: false,
                networkPath: nil,
                connectionVersion: nil
            )
        )

        #expect(report.contains("Network: unavailable"))
        #expect(report.contains("error-domain=SwiftData error-code=134060"))
    }
}
