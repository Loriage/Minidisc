import Foundation
import SwiftSonic
import OSLog

actor RadioService: RadioServiceProtocol {
    private let serverService: any ServerServiceProtocol
    private var cachedClient: SwiftSonicClient?
    private var cachedServerId: UUID?
    private var stationsCache: [InternetRadioStation]?

    init(serverService: any ServerServiceProtocol) {
        self.serverService = serverService
    }

    // MARK: - Client

    private func client() async throws -> SwiftSonicClient {
        let activeId = await MainActor.run { serverService.state.activeServer?.id }
        if let cached = cachedClient, cachedServerId == activeId, activeId != nil {
            return cached
        }
        let fresh = try await serverService.makeSwiftSonicClient()
        cachedClient = fresh
        cachedServerId = activeId
        return fresh
    }

    // MARK: - Read

    func listStations(forceRefresh: Bool = false) async throws -> [InternetRadioStation] {
        if !forceRefresh, let cached = stationsCache { return cached }
        let stations = try await client().getInternetRadioStations()
        stationsCache = stations
        Logger.radio.debug("Fetched \(stations.count) radio station(s).")
        return stations
    }

    func cachedStations() async -> [InternetRadioStation]? {
        stationsCache
    }

    func clearCache() async {
        stationsCache = nil
        Logger.radio.debug("Radio station cache cleared.")
    }
}
