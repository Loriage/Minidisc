import Foundation

// MARK: - YearMonth

nonisolated struct YearMonth: Comparable, Hashable, Sendable, CustomStringConvertible {
    let year: Int
    let month: Int

    var description: String { String(format: "%04d-%02d", year, month) }

    init(year: Int, month: Int) {
        self.year = year
        self.month = month
    }

    init?(string: String) {
        let parts = string.split(separator: "-")
        guard parts.count == 2,
              let y = Int(parts[0]),
              let m = Int(parts[1]),
              m >= 1 && m <= 12 else { return nil }
        year = y
        month = m
    }

    func advanced(by months: Int) -> YearMonth {
        let total = (year - 1) * 12 + (month - 1) + months
        return YearMonth(year: total / 12 + 1, month: total % 12 + 1)
    }

    static func < (lhs: YearMonth, rhs: YearMonth) -> Bool {
        lhs.year != rhs.year ? lhs.year < rhs.year : lhs.month < rhs.month
    }
}

// MARK: - WrappedPreferences

/// Server-scoped Wrapped preferences under minidisc.wrapped.
nonisolated final class WrappedPreferences: Sendable {
    private let userDefaults: LockedUserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = LockedUserDefaults(userDefaults)
    }

    private static func lastMonthKey(_ serverId: String) -> String {
        "minidisc.wrapped.lastUpdatedMonth.\(serverId)"
    }

    private static func playlistIdKey(_ year: Int, _ serverId: String) -> String {
        "minidisc.wrapped.playlistId.\(year).\(serverId)"
    }

    private static func lastYearKey(_ serverId: String) -> String {
        "minidisc.wrapped.lastYear.\(serverId)"
    }

    // MARK: - Last updated month

    func lastUpdatedMonth(serverId: String) -> YearMonth? {
        guard let raw = userDefaults.string(forKey: Self.lastMonthKey(serverId)) else { return nil }
        return YearMonth(string: raw)
    }

    func setLastUpdatedMonth(_ ym: YearMonth, serverId: String) {
        userDefaults.set(ym.description, forKey: Self.lastMonthKey(serverId))
    }

    func clearLastUpdatedMonth(serverId: String) {
        userDefaults.removeObject(forKey: Self.lastMonthKey(serverId))
    }

    // MARK: - Annual playlist ID cache

    func playlistId(year: Int, serverId: String) -> String? {
        userDefaults.string(forKey: Self.playlistIdKey(year, serverId))
    }

    func setPlaylistId(_ id: String, year: Int, serverId: String) {
        userDefaults.set(id, forKey: Self.playlistIdKey(year, serverId))
    }

    /// Clears stale playlist identity so subsequent syncs can recreate a deleted playlist.
    func clearPlaylistId(year: Int, serverId: String) {
        userDefaults.removeObject(forKey: Self.playlistIdKey(year, serverId))
    }

    // MARK: - Last known year marker

    func lastWrappedYear(serverId: String) -> Int? {
        let v = userDefaults.integer(forKey: Self.lastYearKey(serverId))
        return v == 0 ? nil : v
    }

    func setLastWrappedYear(_ year: Int, serverId: String) {
        userDefaults.set(year, forKey: Self.lastYearKey(serverId))
    }
}
