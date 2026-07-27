// Minidisc — Music client for Subsonic/OpenSubsonic servers
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftSonic

protocol RadioServiceProtocol: AnyObject, Sendable {
    func listStations(forceRefresh: Bool) async throws -> [InternetRadioStation]
    func cachedStations() async -> [InternetRadioStation]?
    func clearCache() async
}
