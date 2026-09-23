import Foundation
import Testing
@testable import Minidisc

private nonisolated final class OfflineLidarrProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let code: URLError.Code = switch request.url?.host {
        case "lost.invalid": .networkConnectionLost
        case "cancelled.invalid": .cancelled
        default: .notConnectedToInternet
        }
        client?.urlProtocol(self, didFailWithError: URLError(code))
    }
    override func stopLoading() {}
}

@Suite("Lidarr offline errors")
@MainActor
struct LidarrOfflineTests {
    @Test(arguments: ["offline.invalid", "lost.invalid"])
    func offlineTransportProducesTypedState(host: String) async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OfflineLidarrProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = try #require(LidarrClient(urlString: "https://\(host)", apiKey: "fixture", session: session))
        do {
            _ = try await client.artists()
            Issue.record("Expected offline result")
        } catch let error as LidarrError {
            #expect(error == .offline)
            #expect(!LidarrLibraryView.message(for: error).contains("NSURLErrorDomain"))
        }
    }

    @Test func cancellationIsNotAnOfflineFailure() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OfflineLidarrProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = try #require(LidarrClient(urlString: "https://cancelled.invalid", apiKey: "fixture", session: session))
        do { _ = try await client.artists(); Issue.record("Expected cancellation") }
        catch let error as LidarrError { #expect(error == .cancelled) }
    }

    @Test func technicalErrorsAreNotExposedInTheLibrary() {
        for error in [LidarrError.transport("Error Domain=NSURLErrorDomain Code=-1009 secret"),
                      LidarrError.decoding("DecodingError with server data secret")] {
            let text = LidarrLibraryView.message(for: error)
            #expect(!text.contains("secret"))
            #expect(!text.contains("Error Domain="))
            #expect(!text.isEmpty)
        }
    }
}
