import CryptoKit
import Foundation

/// A configuration can be pointed at another library without making its existing
/// downloads belong to that library. Returning to a previous endpoint/account reuses
/// its original scope, so its local files and preferences remain available.
nonisolated enum ServerLibraryScopes {
    struct Selection: Sendable {
        let id: UUID
        let data: Data
    }

    static func select(currentID: UUID, currentURL: String, currentUser: String,
                       saved: Data?, url: String, user: String) throws -> Selection {
        var scopes = try saved.map { try JSONDecoder().decode([String: UUID].self, from: $0) } ?? [:]
        scopes[key(url: currentURL, user: currentUser)] = currentID
        let destination = key(url: url, user: user)
        let id = scopes[destination] ?? UUID()
        scopes[destination] = id
        return Selection(id: id, data: try JSONEncoder().encode(scopes))
    }

    private static func key(url: String, user: String) -> String {
        var components = URLComponents(string: url.trimmingCharacters(in: .whitespacesAndNewlines))
        let scheme = components?.scheme?.lowercased()
        let host = components?.host?.lowercased()
        components?.scheme = scheme
        components?.host = host
        if components?.port == (components?.scheme == "https" ? 443 : 80) { components?.port = nil }
        if var path = components?.path {
            while path.hasSuffix("/") { path.removeLast() }
            components?.path = path
        }
        let normalized = components?.string ?? url
        return SHA256.hash(data: Data("\(normalized)\u{0}\(user)".utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
