import Foundation
import SwiftSonic
@testable import Minidisc

@MainActor
func playlistServerError(code: Int = 70) async throws -> SwiftSonicError {
    let client = SwiftSonicClient(
        configuration: ServerConfiguration(serverURL: URL(string: "https://example.invalid")!, username: "test", password: "test"),
        transport: StubHTTPTransport(outcome: .response(data: Data("""
            {"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":\(code),"message":"test"}}}
            """.utf8), statusCode: 200)),
        retryPolicy: .none
    )
    do { _ = try await client.getPlaylist(id: "deleted") }
    catch let error as SwiftSonicError { return error }
    throw MinidiscError.notImplemented
}
