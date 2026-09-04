import Foundation
import SwiftSonic

nonisolated enum PlaylistAvailability {
    /// A proxy's HTTP 404 is not evidence that this particular playlist was removed.
    static func isConfirmedMissing(_ error: any Error) -> Bool {
        guard let error = error as? SwiftSonicError,
              case .api(let response) = error else { return false }
        return response.code == .notFound && response.endpoint == "getPlaylist"
    }
}
