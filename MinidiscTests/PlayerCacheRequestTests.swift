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


@Suite("Transcoded seek sources")
struct TranscodedSeekSourceTests {
    @Test func onlyFiniteMP3StreamsNeedACompleteSeekFile() {
        let url = URL(string: "https://music.example/stream?format=mp3&maxBitRate=192")!
        #expect(MediaSource.stream(url, customHeaders: [:]).needsCompleteFileForSeeking)
        #expect(!MediaSource.liveStream(url, customHeaders: [:], stationId: "radio").needsCompleteFileForSeeking)
        #expect(!MediaSource.stream(URL(string: "https://music.example/stream?format=raw")!, customHeaders: [:]).needsCompleteFileForSeeking)
        #expect(!MediaSource.cached(URL(fileURLWithPath: "/tmp/track.mp3")).needsCompleteFileForSeeking)
    }

    @Test func temporaryFileIsDeletedWhenItsPlaybackSourceIsReleased() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1, 2, 3]).write(to: url)
        var source: MediaSource? = .seekBuffer(TranscodedSeekFile(url: url))
        #expect(source?.url == url)
        #expect(FileManager.default.fileExists(atPath: url.path))
        source = nil
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
