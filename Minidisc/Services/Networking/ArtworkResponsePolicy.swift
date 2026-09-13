import Foundation

nonisolated enum ArtworkResponsePolicy {
    /// Navidrome 0.64 returns unresolved artwork as an image with `no-store`.
    /// Saving it in our own cache would bypass URLSession's policy and freeze
    /// that temporary placeholder instead of fetching the real cover later.
    static func isTransient(_ response: URLResponse) -> Bool {
        guard let value = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Cache-Control") else { return false }
        return value.split(separator: ",").contains {
            $0.trimmingCharacters(in: .whitespaces).lowercased() == "no-store"
        }
    }
}
