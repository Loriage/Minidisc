import Foundation
import Testing
@testable import Minidisc

@Suite("Playback diagnostics")
struct PlaybackDiagnosticsTests {
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
