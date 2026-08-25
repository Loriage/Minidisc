import Foundation

nonisolated struct LRCLIBTrackSignature: Equatable, Sendable {
    let title: String
    let artist: String
    let album: String?
    let duration: TimeInterval?
}

nonisolated struct LRCLIBLyricsRecord: Decodable, Equatable, Sendable {
    let id: Int
    let trackName: String
    let artistName: String
    let albumName: String
    let duration: Double
    let instrumental: Bool
    let plainLyrics: String?
    let syncedLyrics: String?
}

nonisolated protocol LRCLIBLyricsFetching: Sendable {
    func lyrics(for signature: LRCLIBTrackSignature) async throws -> LRCLIBLyricsRecord
}

nonisolated protocol LRCLIBTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

nonisolated struct URLSessionLRCLIBTransport: LRCLIBTransport {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

/// Small read-only LRCLIB client. Actor isolation serializes requests and retains rate-limit state.
actor LRCLIBClient: LRCLIBLyricsFetching {
    private static let minimumRequestInterval: TimeInterval = 0.25

    private let transport: any LRCLIBTransport
    private let endpoint: URL
    private let clientIdentifier: String
    private let now: @Sendable () -> Date
    private var rateLimitedUntil: Date?
    private var nextRequestAllowedAt: Date?
    // Actors are reentrant across `await`; this chain prevents overlapping LRCLIB requests as required by its API.
    private var requestTail: Task<LRCLIBLyricsRecord, any Error>?
    private var requestSequence: UInt = 0

    init(
        transport: any LRCLIBTransport = URLSessionLRCLIBTransport(),
        endpoint: URL = LRCLIBClient.defaultEndpoint,
        clientIdentifier: String = LRCLIBClient.defaultClientIdentifier(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.transport = transport
        self.endpoint = endpoint
        self.clientIdentifier = clientIdentifier
        self.now = now
    }

    nonisolated private static var defaultEndpoint: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "lrclib.net"
        components.path = "/api/get"
        guard let url = components.url else {
            preconditionFailure("The static LRCLIB endpoint must be a valid URL")
        }
        return url
    }

    func lyrics(for signature: LRCLIBTrackSignature) async throws -> LRCLIBLyricsRecord {
        let predecessor = requestTail
        requestSequence += 1
        let sequence = requestSequence
        let request = Task { [weak self] () throws -> LRCLIBLyricsRecord in
            if let predecessor {
                _ = try? await predecessor.value
                try Task.checkCancellation()
            }
            guard let self else { throw CancellationError() }
            return try await self.performRequest(for: signature)
        }
        requestTail = request
        defer {
            if sequence == requestSequence {
                requestTail = nil
            }
        }

        return try await withTaskCancellationHandler {
            try await request.value
        } onCancel: {
            request.cancel()
        }
    }

    private func performRequest(for signature: LRCLIBTrackSignature) async throws -> LRCLIBLyricsRecord {
        if let rateLimitedUntil, rateLimitedUntil > now() {
            throw LyricsError.networkError(
                underlying: String(localized: "LRCLIB is temporarily rate-limiting requests. Try again later.")
            )
        }

        if let nextRequestAllowedAt {
            let delay = nextRequestAllowedAt.timeIntervalSince(now())
            if delay > 0 {
                try await Task.sleep(for: .seconds(delay))
            }
        }
        defer {
            nextRequestAllowedAt = now().addingTimeInterval(Self.minimumRequestInterval)
        }

        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw LyricsError.networkError(underlying: "Invalid LRCLIB endpoint")
        }

        var queryItems = [
            URLQueryItem(name: "track_name", value: signature.title),
            URLQueryItem(name: "artist_name", value: signature.artist),
        ]
        if let album = signature.album, !album.isEmpty {
            queryItems.append(URLQueryItem(name: "album_name", value: album))
        }
        if let duration = signature.duration, (1...3_600).contains(duration) {
            queryItems.append(URLQueryItem(
                name: "duration",
                value: String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), duration)
            ))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            throw LyricsError.networkError(underlying: "Invalid LRCLIB request")
        }

        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(clientIdentifier, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await transport.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw LyricsError.networkError(underlying: "Invalid LRCLIB response")
            }

            switch httpResponse.statusCode {
            case 200:
                do {
                    return try JSONDecoder().decode(LRCLIBLyricsRecord.self, from: data)
                } catch {
                    throw LyricsError.networkError(underlying: "Invalid LRCLIB response data")
                }
            case 404:
                throw LyricsError.notFound
            case 429:
                let retryDelay = httpResponse.value(forHTTPHeaderField: "Retry-After")
                    .flatMap(TimeInterval.init) ?? 60
                rateLimitedUntil = now().addingTimeInterval(max(1, retryDelay))
                throw LyricsError.networkError(
                    underlying: String(localized: "LRCLIB is temporarily rate-limiting requests. Try again later.")
                )
            default:
                throw LyricsError.networkError(
                    underlying: "LRCLIB request failed (HTTP \(httpResponse.statusCode))"
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as LyricsError {
            throw error
        } catch {
            throw LyricsError.networkError(underlying: error.localizedDescription)
        }
    }

    nonisolated private static func defaultClientIdentifier() -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "development"
        return "Minidisc/\(version) (https://github.com/Loriage/Minidisc)"
    }
}
