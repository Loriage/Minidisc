import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import Minidisc

@Suite("Autonomous playback diagnostics")
struct AutonomousPlaybackDiagnosticsTests {
    @Test func reportAndArchiveIdentifyTheObservedStreamingEngine() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let diagnostics = PlaybackDiagnostics(persistenceDirectory: directory)
        #expect(report(diagnostics).contains("engine=not-yet-observed"))
        diagnostics.record(.streamingEngineSnapshot(.init(
            token: .init(rawValue: 1), state: .buffering, position: 0, duration: 174,
            renderedFrames: 0, intended: true, seeking: false, queued: false,
            overlapping: false, airPlay: false
        )))
        // Discarding the active observation for a new song must not forget the engine type.
        diagnostics.record(.command(.play(queueCount: 2, startIndex: 1)))
        let output = report(diagnostics)
        #expect(output.contains("; engine=AudioStreaming"))
        #expect(!output.contains("engine=AVQueuePlayer"))
        diagnostics.flush()
        let archived = report(PlaybackDiagnostics(persistenceDirectory: directory))
        #expect(archived.contains("; engine=AudioStreaming"))
        #expect(!archived.contains("engine=AVQueuePlayer"))
    }

    private func report(_ diagnostics: PlaybackDiagnostics) -> String {
        diagnostics.makeReport(context: .init(appVersion: "test", appBuild: "0", operatingSystem: "test",
            playbackStatus: .playing, isPlaybackAvailable: true, networkPath: nil, connectionVersion: nil))
    }

    @Test func healthDetectsSilentStallsWithoutWaitingForAVFoundationErrors() {
        var health = PlaybackDiagnosticHealth()
        let token = AudioEnginePlaybackToken(rawValue: 1)
        for time in 0..<10 {
            #expect(health.observe(token: token, position: 0, intended: true, waitingAtBoundary: false, at: Double(time)) == nil)
        }
        #expect(health.observe(token: token, position: 0, intended: true, waitingAtBoundary: false, at: 10)?.0 == .startupNotProgressing)
        #expect(health.observe(token: token, position: 0, intended: true, waitingAtBoundary: false, at: 11) == nil)
        #expect(health.observe(token: token, position: 0.5, intended: true, waitingAtBoundary: false, at: 12)?.0 == .progressRecovered)
        for time in 13..<22 {
            #expect(health.observe(token: token, position: 0.5, intended: true, waitingAtBoundary: false, at: Double(time)) == nil)
        }
        #expect(health.observe(token: token, position: 0.5, intended: true, waitingAtBoundary: false, at: 22)?.0 == .clockStopped)
    }

    @Test func healthDistinguishesHandoffPauseSeekAndSuspension() {
        var health = PlaybackDiagnosticHealth()
        let token = AudioEnginePlaybackToken(rawValue: 1)
        for time in 0..<3 {
            #expect(health.observe(token: token, position: 120, intended: true, waitingAtBoundary: true, at: Double(time)) == nil)
        }
        #expect(health.observe(token: token, position: 120, intended: true, waitingAtBoundary: true, at: 3)?.0 == .queueHandoffDelayed)
        #expect(health.observe(token: token, position: 120, intended: false, waitingAtBoundary: true, at: 4) == nil)
        #expect(health.observe(token: token, position: 120, intended: true, waitingAtBoundary: true, at: 5) == nil)
        #expect(health.observe(token: token, position: 120, intended: true, waitingAtBoundary: true, at: 200)?.0 == .samplingGap)
        #expect(health.observe(token: .init(rawValue: 2), position: 0, intended: true, waitingAtBoundary: false, at: 201) == nil)
        health.reset() // Explicit seek resets observation, independently of transport recovery.
        #expect(health.observe(token: .init(rawValue: 2), position: 40, intended: true, waitingAtBoundary: false, at: 220) == nil)
    }

    @Test func incidentContextSurvivesEvictionAndAnotherLaunchWithoutSecrets() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let diagnostics = PlaybackDiagnostics(capacity: 2, persistenceDirectory: directory)
        diagnostics.record(.networkPathChanged(.init(.initial)))
        diagnostics.record(.sourceRequest(.init(rawValue: 1), .init(
            url: URL(string: "https://PRIVATE_USER:PRIVATE_PASSWORD@PRIVATE_HOST/PRIVATE_SONG?token=PRIVATE_TOKEN&format=raw")!, headerCount: 2)))
        diagnostics.record(.health(.init(rawValue: 1), .startupNotProgressing, seconds: 10))
        diagnostics.record(.health(.init(rawValue: 1), .progressRecovered, seconds: 12))
        diagnostics.record(.application(.launchFailed(errorDomain: "PRIVATE_SERVER_ERROR_DOMAIN", errorCode: 5)))
        for index in 0..<40 { diagnostics.record(.command(.play(queueCount: 50, startIndex: index))) }
        diagnostics.flush()

        let reloaded = PlaybackDiagnostics(persistenceDirectory: directory)
        let output = report(reloaded)
        #expect(output.contains("PREVIOUS LAUNCHES"))
        #expect(output.contains("AUTOMATIC INCIDENT CAPTURES"))
        #expect(output.contains("startup-not-progressing"))
        #expect(output.contains("progress-recovered"))
        #expect(output.contains("requested-format=raw"))
        #expect(output.contains("evicted-events="))
        #expect(!output.contains("PRIVATE_"))
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(files.count == 1)
        let onDisk = try String(contentsOf: #require(files.first), encoding: .utf8)
        #expect(!onDisk.contains("PRIVATE_"))
        #expect(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test func archiveBoundsRetainedLaunchesAndIgnoresCorruptData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 1...6 {
            let diagnostics = PlaybackDiagnostics(persistenceDirectory: directory)
            diagnostics.record(.application(.launchStarted(attempt: index)))
            diagnostics.flush()
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(files.count == 4)
        try Data("corrupt PRIVATE_SECRET".utf8).write(to: directory.appendingPathComponent("broken.json"))
        let output = report(PlaybackDiagnostics(persistenceDirectory: directory))
        #expect(!output.contains("attempt=1"))
        #expect(!output.contains("attempt=2"))
        #expect(output.contains("attempt=6"))
        #expect(!output.contains("PRIVATE_SECRET"))
    }

    @Test func responseMetadataIsAllowlisted() throws {
        var result = PlaybackStreamProbe.Result()
        let response = try #require(HTTPURLResponse(url: URL(string: "https://PRIVATE_HOST/PRIVATE_SONG")!, statusCode: 200,
            httpVersion: "HTTP/2", headerFields: ["Content-Type": "audio/PRIVATE_SECRET", "Content-Range": "PRIVATE_RANGE",
                                                "Content-Length": "PRIVATE_LENGTH", "X-Secret": "PRIVATE_TOKEN"]))
        result.observe(response)
        result.observePrefix(Array("<html>PRIVATE_SECRET</html>".utf8))
        #expect(result.content == .audio)
        #expect(result.payload == .markup)
        #expect(result.byteRange == nil)
        #expect(result.contentLength == nil)
        #expect(!result.description.contains("PRIVATE_"))
    }

    @Test func streamProbeLimitsBodyReadAndReportsActualHTTPResponse() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DiagnosticProbeURLProtocol.self]
        let result = await PlaybackStreamProbe.run(url: URL(string: "https://probe.invalid/audio")!, headers: [:], configuration: configuration)
        #expect(result.status == 206)
        #expect(result.bytesRead == 1_024)
        #expect(result.payload == .audioSignature)
        #expect(result.content == .audio)
        #expect(result.byteRange == "bytes 0-1023/4096")
        #expect(result.firstByteSeconds != nil)
        #expect(result.failure == nil)
    }

    @Test func streamProbeRecordsHTTPAndNetworkFailuresWithoutTheirBodies() async {
        for path in ["denied", "timeout"] {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [DiagnosticProbeURLProtocol.self]
            let result = await PlaybackStreamProbe.run(url: URL(string: "https://probe.invalid/\(path)")!, headers: [:], configuration: configuration)
            if path == "denied" {
                #expect(result.status == 403)
                #expect(result.payload == .json)
            } else {
                #expect(result.failure?.codes.diagnosticMeaning == "request-timeout")
            }
            #expect(!result.description.contains("PRIVATE_"))
        }
    }
}

private nonisolated final class DiagnosticProbeURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "probe.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        guard request.value(forHTTPHeaderField: "Range") == "bytes=0-1023" else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        if url.path == "/timeout" {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return
        }
        let denied = url.path == "/denied"
        let response = HTTPURLResponse(url: url, statusCode: denied ? 403 : 206, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": denied ? "application/json" : "audio/flac",
                           "Content-Range": "bytes 0-1023/4096", "Accept-Ranges": "bytes"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = denied ? Data("{\"message\":\"PRIVATE_SECRET\"}".utf8) : Data("fLaC".utf8) + Data(count: 4_092)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
