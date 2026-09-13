import Foundation
import SwiftData

@Model
final class ServerConfig {
    var id: UUID
    var displayName: String
    var baseURL: String
    var username: String
    var isActive: Bool
    var serverVersion: String?
    var createdAt: Date
    /// AudioMuse endpoint for this server. Its token is stored separately in Keychain.
    var audioMuseURL: String?

    // password + customHeaders are stored in Keychain only.
    // Keychain key: ServerCredentials.keychainKey(for: id)

    init(
        id: UUID = UUID(),
        displayName: String,
        baseURL: String,
        username: String,
        isActive: Bool = false,
        serverVersion: String? = nil,
        createdAt: Date = Date(),
        audioMuseURL: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.username = username
        self.isActive = isActive
        self.serverVersion = serverVersion
        self.createdAt = createdAt
        self.audioMuseURL = audioMuseURL
    }
}
