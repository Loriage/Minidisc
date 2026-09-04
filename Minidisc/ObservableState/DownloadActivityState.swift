import Foundation
import Observation

@Observable @MainActor
final class DownloadActivityState {
    var transfers: [DownloadProgress] = []
}
