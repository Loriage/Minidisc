import CryptoKit
import Foundation

/// Mirrors Navidrome v0.64.0's uniform_canonical_ids migration, including its
/// historical random-ID overflow rule. Only apply to Navidrome resource IDs,
/// never MusicBrainz UUIDs, local UUIDs, share tokens, or another server's IDs.
/// https://github.com/navidrome/navidrome/blob/v0.64.0/db/migrations/20260720015443_uniform_canonical_ids.go
nonisolated enum NavidromeCanonicalID {
    private static let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")

    static func isRequired(serverType: String?, version: String?) -> Bool {
        guard serverType?.lowercased() == "navidrome", let version else { return false }
        let release = version.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingPrefix("v").split(whereSeparator: { $0.isWhitespace || $0 == "(" || $0 == "+" }).first ?? ""
        let components = release.split(separator: ".")
        guard components.count == 3,
              let major = Int(components[0]), let minor = Int(components[1]),
              let patch = Int(components[2]), major >= 0, minor >= 0, patch >= 0 else { return false }
        return major > 0 || minor >= 64
    }

    static func convert(_ id: String) -> String {
        switch id.utf8.count {
        case 22:
            guard id.allSatisfy({ alphabet.contains($0) }) else { return id }
            var value: UInt128 = 0
            for character in id {
                let digit = UInt128(alphabet.firstIndex(of: character)!)
                let product = value.multipliedReportingOverflow(by: 62)
                let sum = product.partialValue.addingReportingOverflow(digit)
                if product.overflow || sum.overflow {
                    // Navidrome uses plain MD5 here, not its separator-based NewHash.
                    return encode(Insecure.MD5.hash(data: Data(id.utf8)).reduce(UInt128(0)) { ($0 << 8) | UInt128($1) })
                }
                value = sum.partialValue
            }
            return id
        case 32:
            guard id.allSatisfy({ $0.isASCII && $0.isHexDigit }),
                  let value = UInt128(id, radix: 16) else { return id }
            return encode(value)
        case 36:
            let characters = Array(id)
            guard characters.count == 36, [8, 13, 18, 23].allSatisfy({ characters[$0] == "-" }) else { return id }
            let hex = id.replacingOccurrences(of: "-", with: "")
            guard hex.count == 32, hex.allSatisfy({ $0.isASCII && $0.isHexDigit }),
                  let value = UInt128(hex, radix: 16) else { return id }
            return encode(value)
        default:
            return id
        }
    }

    static func artwork(_ id: String) -> String {
        let prefix = String(id.prefix(3))
        guard ["mf-", "al-", "ar-", "pl-", "dc-", "ra-"].contains(prefix) else { return convert(id) }
        let parts = id.dropFirst(3).split(separator: "_", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first, !first.isEmpty else { return id }
        let resource = first.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let disc = resource.count == 2 ? ":" + resource[1] : ""
        let suffix = parts.count == 2 ? "_" + parts[1] : ""
        return prefix + convert(String(resource[0])) + disc + suffix
    }

    /// The input is a song DTO (or an array of songs), not an arbitrary document.
    /// An explicit key list preserves MusicBrainz IDs and all non-ID metadata.
    static func songData(_ data: Data) throws -> Data {
        let root = try JSONSerialization.jsonObject(with: data)
        func rewrite(_ value: Any) -> Any {
            if let array = value as? [Any] { return array.map(rewrite) }
            guard let object = value as? [String: Any] else { return value }
            return object.reduce(into: [String: Any]()) { result, pair in
                if let string = pair.value as? String,
                   ["id", "parent", "albumId", "artistId"].contains(pair.key) {
                    result[pair.key] = convert(string)
                } else if let string = pair.value as? String,
                          ["coverArt", "coverArtId"].contains(pair.key) {
                    result[pair.key] = artwork(string)
                } else { result[pair.key] = rewrite(pair.value) }
            }
        }
        return try JSONSerialization.data(withJSONObject: rewrite(root), options: [.sortedKeys])
    }

    static func containsLegacyIDs(in data: Data) throws -> Bool {
        let normalized = try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: data), options: [.sortedKeys])
        return try songData(data) != normalized
    }

    private static func encode(_ value: UInt128) -> String {
        var value = value
        var result = [Character](repeating: "0", count: 22)
        for index in result.indices.reversed() {
            result[index] = alphabet[Int(value % 62)]
            value /= 62
        }
        return String(result)
    }
}
