import Foundation
import SwiftSonic
import OSLog

actor RadioService: RadioServiceProtocol {
    private let serverService: any ServerServiceProtocol
    private var cachedClient: SwiftSonicClient?
    private var cachedConnectionVersion: ServerConnection.Version?
    private var stationsCache: [InternetRadioStation]?

    init(serverService: any ServerServiceProtocol) {
        self.serverService = serverService
    }

    // MARK: - Client

    private func client() async throws -> SwiftSonicClient {
        let activeVersion = await serverService.activeConnectionVersion()
        if let cached = cachedClient,
           let activeVersion,
           cachedConnectionVersion == activeVersion {
            return cached
        }
        let connection = try await serverService.activeConnection()
        let fresh = connection.makeSwiftSonicClient()
        cachedClient = fresh
        cachedConnectionVersion = connection.version
        stationsCache = nil
        return fresh
    }

    // MARK: - Read

    func listStations(forceRefresh: Bool = false) async throws -> [InternetRadioStation] {
        let client = try await client()
        if !forceRefresh, let cached = stationsCache { return cached }
        let stations = try await client.getInternetRadioStations()
        stationsCache = stations
        Logger.radio.debug("Fetched \(stations.count) radio station(s).")
        return stations
    }

    func cachedStations() async -> [InternetRadioStation]? {
        if await serverService.activeConnectionVersion() != cachedConnectionVersion {
            cachedClient = nil
            cachedConnectionVersion = nil
            stationsCache = nil
        }
        return stationsCache
    }

    func clearCache() async {
        stationsCache = nil
        Logger.radio.debug("Radio station cache cleared.")
    }
}
