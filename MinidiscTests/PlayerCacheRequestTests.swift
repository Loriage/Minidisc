import Foundation
import Testing
@testable import Minidisc

@Suite("Player cache requests")
struct PlayerCacheRequestTests {
    @Test(arguments: [false, true])
    func completeTranscodeDownloadDoesNotInheritEstimatedLength(cellular: Bool) throws {
        let url = try #require(URL(string: "https://music.example/rest/stream?id=a&format=mp3&maxBitRate=192&estimateContentLength=true&t=token%2Bvalue"))
        let request = PlayerService.cacheDownloadRequest(
            url: url, headers: ["Authorization": "Bearer fixture"], allowCellular: cellular
        )
        let requestURL = try #require(request.url)
        let components = try #require(URLComponents(url: requestURL, resolvingAgainstBaseURL: false))
        let query = components.queryItems ?? []
        #expect(query.filter { $0.name == "estimateContentLength" }.map(\.value) == ["false"])
        #expect(query.contains(URLQueryItem(name: "format", value: "mp3")))
        #expect(query.contains(URLQueryItem(name: "maxBitRate", value: "192")))
        #expect(query.contains(URLQueryItem(name: "t", value: "token+value")))
        #expect(components.percentEncodedQuery?.contains("t=token%2Bvalue") == true)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")
        #expect(request.allowsCellularAccess == cellular)
    }
}
