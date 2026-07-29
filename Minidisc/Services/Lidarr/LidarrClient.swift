import Foundation
import OSLog

nonisolated enum LidarrError: Error, Equatable, Sendable {
    case badURL
    case unauthorized
    case htmlResponse
    case cancelled
    case transport(String)
    case decoding(String)
}

nonisolated struct LidarrSystemStatus: Decodable, Sendable, Equatable {
    let version: String
    let instanceName: String?
    let appName: String?
}

private nonisolated struct LidarrArtistLite: Decodable {
    let id: Int
}

actor LidarrClient {
    private let baseURL: URL
    private let apiKey: String
    private let headers: [String: String]
    private let session: URLSession

    static let requestTimeout: TimeInterval = 20

    init?(urlString: String, apiKey: String, headers: [String: String] = [:], session: URLSession = .shared) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil else { return nil }
        self.baseURL = url
        self.apiKey = apiKey
        self.headers = headers
        self.session = session
    }

    func systemStatus() async throws -> LidarrSystemStatus {
        try await get(path: "/api/v1/system/status")
    }

    func artistCount() async throws -> Int {
        let artists: [LidarrArtistLite] = try await get(path: "/api/v1/artist")
        return artists.count
    }

    func searchArtists(term: String) async throws -> [LidarrArtistLookup] {
        try await get(path: "/api/v1/artist/lookup", query: [URLQueryItem(name: "term", value: term)])
    }

    func qualityProfiles() async throws -> [LidarrProfile] {
        try await get(path: "/api/v1/qualityprofile")
    }

    func metadataProfiles() async throws -> [LidarrProfile] {
        try await get(path: "/api/v1/metadataprofile")
    }

    func rootFolders() async throws -> [LidarrRootFolder] {
        try await get(path: "/api/v1/rootfolder")
    }

    func addArtist(_ request: LidarrAddArtistRequest) async throws {
        try await postJSON(path: "/api/v1/artist", body: request)
    }

    func artists() async throws -> [LidarrArtist] {
        try await get(path: "/api/v1/artist")
    }

    func albums(artistId: Int) async throws -> [LidarrAlbum] {
        try await get(path: "/api/v1/album", query: [URLQueryItem(name: "artistId", value: String(artistId))])
    }

    func tracks(albumId: Int) async throws -> [LidarrTrack] {
        try await get(path: "/api/v1/track", query: [URLQueryItem(name: "albumId", value: String(albumId))])
    }

    func triggerAlbumSearch(albumIds: [Int]) async throws {
        try await postJSON(path: "/api/v1/command", body: LidarrAlbumSearchCommand(name: "AlbumSearch", albumIds: albumIds))
    }

    func releases(albumId: Int) async throws -> [LidarrRelease] {
        try await get(path: "/api/v1/release", query: [URLQueryItem(name: "albumId", value: String(albumId))], timeout: 120)
    }

    func releases(artistId: Int) async throws -> [LidarrRelease] {
        try await get(path: "/api/v1/release", query: [URLQueryItem(name: "artistId", value: String(artistId))], timeout: 120)
    }

    func grabRelease(guid: String, indexerId: Int, albumId: Int? = nil, artistId: Int? = nil) async throws {
        try await postJSON(path: "/api/v1/release", body: LidarrGrabRequest(guid: guid, indexerId: indexerId, albumId: albumId, artistId: artistId))
    }

    func triggerArtistSearch(artistId: Int) async throws {
        try await postJSON(path: "/api/v1/command", body: LidarrCommand(name: "ArtistSearch", artistId: artistId))
    }

    func refreshArtist(artistId: Int) async throws {
        try await postJSON(path: "/api/v1/command", body: LidarrCommand(name: "RefreshArtist", artistId: artistId))
    }

    func setAlbumsMonitored(albumIds: [Int], monitored: Bool) async throws {
        try await putJSON(path: "/api/v1/album/monitor", body: LidarrAlbumMonitorRequest(albumIds: albumIds, monitored: monitored))
    }

    func deleteArtist(artistId: Int, deleteFiles: Bool) async throws {
        try await deleteRequest(path: "/api/v1/artist/\(artistId)", query: [URLQueryItem(name: "deleteFiles", value: String(deleteFiles))])
    }

    func queue() async throws -> [LidarrQueueItem] {
        let response: LidarrQueueResponse = try await get(path: "/api/v1/queue", query: [
            URLQueryItem(name: "pageSize", value: "200"),
            URLQueryItem(name: "includeArtist", value: "true"),
            URLQueryItem(name: "includeAlbum", value: "true"),
            URLQueryItem(name: "includeUnknownArtistItems", value: "true"),
        ])
        return response.records
    }

    func removeQueueItem(
        id: Int,
        removeFromClient: Bool,
        blocklist: Bool,
        searchForReplacement: Bool
    ) async throws {
        try await deleteRequest(path: "/api/v1/queue/\(id)", query: [
            URLQueryItem(name: "removeFromClient", value: String(removeFromClient)),
            URLQueryItem(name: "blocklist", value: String(blocklist)),
            URLQueryItem(name: "skipRedownload", value: String(!searchForReplacement)),
        ])
    }

    func manualImportCandidates(downloadId: String) async throws -> [LidarrManualImportFile] {
        try await get(path: "/api/v1/manualimport", query: [
            URLQueryItem(name: "downloadId", value: downloadId),
            URLQueryItem(name: "filterExistingFiles", value: "false"),
        ], timeout: 60)
    }

    func runManualImport(files: [LidarrManualImportFileRequest], importMode: LidarrImportMode) async throws {
        try await postJSON(path: "/api/v1/command", body: LidarrManualImportCommand(files: files, importMode: importMode))
    }

    func imageData(forPath path: String) async throws -> Data {
        let request: URLRequest
        if path.hasPrefix("http") {
            guard let url = URL(string: path) else { throw LidarrError.badURL }
            request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
        } else {
            let base = baseURL.absoluteString
            let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
            guard let url = URL(string: trimmed + path) else { throw LidarrError.badURL }
            var r = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
            r.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
            for (name, value) in headers { r.setValue(value, forHTTPHeaderField: name) }
            request = r
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw LidarrError.transport("image request failed")
        }
        return data
    }

    private func get<T: Decodable>(path: String, query: [URLQueryItem] = [], timeout: TimeInterval? = nil) async throws -> T {
        var request = try makeRequest(path: path, query: query, method: "GET", timeout: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await send(request)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw LidarrError.decoding(String(describing: error))
        }
    }

    private func postJSON<Body: Encodable>(path: String, body: Body) async throws {
        try await sendBody(path: path, method: "POST", body: body)
    }

    private func putJSON<Body: Encodable>(path: String, body: Body) async throws {
        try await sendBody(path: path, method: "PUT", body: body)
    }

    private func sendBody<Body: Encodable>(path: String, method: String, body: Body) async throws {
        var request = try makeRequest(path: path, query: [], method: method)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONEncoder().encode(body)
        _ = try await send(request)
    }

    private func deleteRequest(path: String, query: [URLQueryItem]) async throws {
        let request = try makeRequest(path: path, query: query, method: "DELETE")
        _ = try await send(request)
    }

    private func makeRequest(path: String, query: [URLQueryItem], method: String, timeout: TimeInterval? = nil) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { throw LidarrError.badURL }
        components.path = (components.path as NSString).appendingPathComponent(path)
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw LidarrError.badURL }
        var request = URLRequest(url: url, timeoutInterval: timeout ?? Self.requestTimeout)
        request.httpMethod = method
        request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw LidarrError.cancelled
        } catch {
            throw LidarrError.transport(String(describing: error))
        }

        guard let http = response as? HTTPURLResponse else { throw LidarrError.transport("non-HTTP response") }
        if Self.looksLikeHTML(data: data, response: http) { throw LidarrError.htmlResponse }
        switch http.statusCode {
        case 200...299:
            return data
        case 401, 403:
            throw LidarrError.unauthorized
        default:
            if let message = Self.firstErrorMessage(in: data) {
                throw LidarrError.transport(message)
            }
            throw LidarrError.transport("HTTP \(http.statusCode)")
        }
    }

    private static func firstErrorMessage(in data: Data) -> String? {
        if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
           let message = array.first?["errorMessage"] as? String {
            return message
        }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = object["message"] as? String {
            return message
        }
        return nil
    }

    private static func looksLikeHTML(data: Data, response: HTTPURLResponse) -> Bool {
        if let type = response.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
           type.contains("html") {
            return true
        }
        let whitespace: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D]
        if let first = data.first(where: { !whitespace.contains($0) }) {
            return first == UInt8(ascii: "<")
        }
        return false
    }
}
