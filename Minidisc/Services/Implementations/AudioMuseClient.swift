import Foundation
import OSLog

nonisolated enum AudioMuseError: Error, Equatable, Sendable {
    /// HTTP 400 — usually `CLAP_ENABLED=false` on the instance. Carries the server's own message,
    /// which distinguishes "search disabled" from the rarer bad-parameter cases.
    case searchDisabled(String?)
    /// The sonic analysis has never been run, so there is no index to query (HTTP 503).
    case notAnalysed
    case unauthorized
    case badURL
    /// AudioMuse fp_ IDs need metadata resolution before use with Subsonic.
    case internalIdsOnly
    case transport(String)
    case decoding(String)
}

/// CLAP search result. item_id may be an internal fp_ ID requiring metadata resolution.
nonisolated struct AudioMuseTrack: Decodable, Sendable, Equatable {
    let itemId: String
    let title: String?
    /// AudioMuse names this `author`. Note it is `artist` on the chat endpoints — the API is not
    /// consistent across routes, so do not share this type with them.
    let author: String?
    let album: String?
    let similarity: Double?

    enum CodingKeys: String, CodingKey {
        case itemId = "item_id"
        case title, author, album, similarity
    }

    var hasInternalId: Bool { itemId.hasPrefix(AudioMuseClient.internalIdPrefix) }

    var descriptor: TrackDescriptor? {
        guard let title, !title.isEmpty else { return nil }
        return TrackDescriptor(title: title, artist: author, album: album)
    }
}

private nonisolated struct ClapSearchResponse: Decodable {
    let results: [AudioMuseTrack]
}

private nonisolated struct ServersResponse: Decodable {
    nonisolated struct Server: Decodable {
        let serverId: String?
        let name: String?
        enum CodingKeys: String, CodingKey { case serverId = "server_id", name }
    }
    let servers: [Server]
    let defaultId: String?
    enum CodingKeys: String, CodingKey { case servers, defaultId = "default_id" }
}

/// AudioMuse warmup and CLAP search client, with authentication separate from Subsonic.
actor AudioMuseClient {
    private let baseURL: URL
    private let token: String?
    private let session: URLSession
    /// Scopes searches to the media server resolved from /api/servers to obtain usable track IDs.
    private var selectedServer: String??

    static let internalIdPrefix = "fp_" 

    /// Allows time for a cold CLAP model to load.
    static let requestTimeout: TimeInterval = 120

    init?(urlString: String, token: String?, session: URLSession = .shared) {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme != nil, url.host != nil else { return nil }
        self.baseURL = url
        self.token = token
        self.session = session
    }

    /// Warms the CLAP model before searching. Failure is nonfatal; callers may still search.
    @discardableResult
    func warmup() async -> Bool {
        await resolveServerIfNeeded()
        do {
            _ = try await send(path: "/api/clap/warmup", body: nil)
            return true
        } catch {
            Logger.moodPlaylists.warning("[AUDIOMUSE] warmup failed, searching cold: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Reads `/api/servers` and keeps the default server's id, so searches can be scoped to it.
    /// Failure is not fatal — the search still runs unscoped and the fp_ guard catches the fallout.
    private func resolveServerIfNeeded() async {
        guard selectedServer == nil else { return }
        do {
            let data = try await send(path: "/api/servers", body: nil, method: "GET")
            let decoded = try JSONDecoder().decode(ServersResponse.self, from: data)
            let resolved = decoded.defaultId ?? decoded.servers.first?.serverId ?? decoded.servers.first?.name
            selectedServer = .some(resolved)
            Logger.moodPlaylists.info("[AUDIOMUSE] \(decoded.servers.count, privacy: .public) server(s) configured, scoping to '\(resolved ?? "default", privacy: .public)'")
        } catch {
            selectedServer = .some(nil)
            Logger.moodPlaylists.warning("[AUDIOMUSE] could not list servers, searching unscoped: \(String(describing: error), privacy: .public)")
        }
    }

    /// CLAP search accepts English queries and a server-clamped limit of 1...500.
    func search(query: String, limit: Int) async throws -> [AudioMuseTrack] {
        await resolveServerIfNeeded()
        var body: [String: Any] = ["query": query, "limit": limit]
        if let server = selectedServer ?? nil { body["server"] = server }
        let payload = try JSONSerialization.data(withJSONObject: body)
        let data = try await send(path: "/api/clap/search", body: payload)

        let results: [AudioMuseTrack]
        do {
            results = try JSONDecoder().decode(ClapSearchResponse.self, from: data).results
        } catch {
            throw AudioMuseError.decoding(String(describing: error))
        }

        return results
    }

    private func send(path: String, body: Data?, method: String = "POST") async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL) else { throw AudioMuseError.badURL }
        var request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AudioMuseError.transport(String(describing: error))
        }

        guard let http = response as? HTTPURLResponse else { throw AudioMuseError.transport("non-HTTP response") }
        switch http.statusCode {
        case 200...299:  return data
        case 400:        throw AudioMuseError.searchDisabled(Self.errorMessage(in: data))
        case 401, 403:   throw AudioMuseError.unauthorized
        case 503:        throw AudioMuseError.notAnalysed
        default:         throw AudioMuseError.transport("HTTP \(http.statusCode)")
        }
    }

    /// AudioMuse reports failures as `{"error": "..."}`. Returns nil when the body is not that shape.
    private static func errorMessage(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["error"] as? String
    }
}
