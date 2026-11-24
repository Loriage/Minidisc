import Foundation
import Testing
@testable import Minidisc

@Suite("Lidarr artist tags")
struct LidarrTagsTests {
    @Test func existingTagsUseTheAuthenticatedInstancePath() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let client = try #require(LidarrClient(urlString: "https://tags.invalid/lidarr", apiKey: "fixture", session: session))
        let tags = try await client.tags()
        #expect(tags.map(\.id) == [42, 7])
        #expect(tags.map(\.label) == ["alternate-client", "lossless"])
    }

    @Test(arguments: [[], [42], [42, 7, 42]])
    func tagsAreSentInTheInitialArtistRequest(ids: [Int]) async throws {
        let host = ids.isEmpty ? "none.invalid" : ids.count == 1 ? "one.invalid" : "many.invalid"
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let client = try #require(LidarrClient(urlString: "https://\(host)/lidarr", apiKey: "fixture", session: session))
        let artist = LidarrArtistLookup(foreignArtistId: "b071f9fa-14b0-4217-8e97-eb41da73f598",
                                       artistName: "Fixture artist", disambiguation: nil, overview: nil,
                                       existingId: nil, remotePoster: nil, images: nil)
        let request = LidarrAddArtistRequest(artist: artist, qualityProfileId: 1, metadataProfileId: 1,
                                             rootFolderPath: "/music", monitor: .all,
                                             searchForMissingAlbums: true, tags: Set(ids))
        try await client.addArtist(request)
    }

    @Test func failedTagFetchIsNotAnEmptyCatalog() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let client = try #require(LidarrClient(urlString: "https://denied.invalid/lidarr", apiKey: "fixture", session: session))
        do {
            _ = try await client.tags()
            Issue.record("An unavailable tag catalog must not be treated as having no tags")
        } catch let error as LidarrError {
            #expect(error == .unauthorized)
        }
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LidarrTagsProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private nonisolated final class LidarrTagsProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        var status = 422
        var body = Data(#"{"message":"Unexpected Lidarr tag request"}"#.utf8)
        if url.host == "denied.invalid" {
            status = 401
        } else if request.value(forHTTPHeaderField: "X-Api-Key") == "fixture" {
            if request.httpMethod == "GET", url.path == "/lidarr/api/v1/tag" {
                status = 200
                body = Data(#"[{"id":42,"label":"alternate-client"},{"id":7,"label":"lossless"}]"#.utf8)
            } else if request.httpMethod == "POST", url.path == "/lidarr/api/v1/artist",
                      let json = try? JSONSerialization.jsonObject(with: requestBody()) as? [String: Any] {
                let expected = url.host == "none.invalid" ? [] : url.host == "one.invalid" ? [42] : [7, 42]
                let options = json["addOptions"] as? [String: Any]
                if json["tags"] as? [Int] == expected,
                   options?["searchForMissingAlbums"] as? Bool == true,
                   json["foreignArtistId"] as? String == "b071f9fa-14b0-4217-8e97-eb41da73f598" {
                    status = 201
                    body = Data(#"{"id":1}"#.utf8)
                }
            }
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func requestBody() -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&bytes, maxLength: bytes.count)
            guard count > 0 else { break }
            data.append(contentsOf: bytes.prefix(count))
        }
        return data
    }
}
