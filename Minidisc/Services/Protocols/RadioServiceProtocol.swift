import SwiftSonic

protocol RadioServiceProtocol: AnyObject, Sendable {
    func listStations(forceRefresh: Bool) async throws -> [InternetRadioStation]
    func cachedStations() async -> [InternetRadioStation]?
    func clearCache() async
}
