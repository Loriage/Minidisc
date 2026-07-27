// Minidisc — Music client for Subsonic/OpenSubsonic servers
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import Security
import OSLog

actor KeychainService: KeychainServiceProtocol {
    // kSecAttrService groups all Minidisc credentials for bulk queries and cleanup.
    private let service = "app.minidisc.server-credentials"

    func store<T: Codable & Sendable>(_ value: T, forKey key: String) async throws {
        let data = try JSONEncoder().encode(value)

        let itemQuery: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let attributes: [String: Any] = [
            kSecValueData as String:      data,
            // AfterFirstUnlock allows Keychain reads while the screen is locked,
            // required for auto-next playback transitions triggered in lock screen.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        // Update in place so a failed write never destroys the previous credential.
        // The old delete-then-add sequence left the account permanently signed out when
        // SecItemAdd failed (locked Keychain, entitlement issue, or transient OS error).
        let updateStatus = SecItemUpdate(itemQuery as CFDictionary, attributes as CFDictionary)
        let status: OSStatus
        if updateStatus == errSecItemNotFound {
            var addQuery = itemQuery
            attributes.forEach { addQuery[$0.key] = $0.value }
            status = SecItemAdd(addQuery as CFDictionary, nil)
        } else {
            status = updateStatus
        }

        guard status == errSecSuccess else {
            // Never log `data` — it may contain credentials.
            Logger.keychain.error("Keychain write failed for key '\(key, privacy: .public)' — OSStatus \(status)")
            throw MinidiscError.keychainWriteFailed(status)
        }
    }

    func retrieve<T: Codable & Sendable>(_ type: T.Type, forKey key: String) async throws -> T? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status != errSecItemNotFound else { return nil }
        guard status == errSecSuccess else {
            Logger.keychain.error("Keychain read failed for key '\(key, privacy: .public)' — OSStatus \(status)")
            throw MinidiscError.keychainReadFailed(status)
        }

        guard let data = result as? Data else { return nil }
        return try JSONDecoder().decode(type, from: data)
    }

    func delete(forKey key: String) async throws {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            Logger.keychain.error("Keychain delete failed for key '\(key, privacy: .public)' — OSStatus \(status)")
            throw MinidiscError.keychainDeleteFailed(status)
        }
    }
}
