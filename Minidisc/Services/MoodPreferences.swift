import Foundation

nonisolated enum MoodCycle {
    static let refreshWeekday = 4

    static func start(for date: Date, calendar: Calendar) -> Date {
        let startOfDay = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: startOfDay)
        let daysSinceWednesday = (weekday - refreshWeekday + 7) % 7
        return calendar.date(byAdding: .day, value: -daysSinceWednesday, to: startOfDay) ?? startOfDay
    }
}

nonisolated struct MoodPreferences: Sendable {
    private nonisolated(unsafe) let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    private static func cycleKey(_ mood: Mood, _ serverId: String) -> String {
        "minidisc.mood.syncedCycle.\(mood.rawValue).\(serverId)"
    }
    private static func playlistIdKey(_ mood: Mood, _ serverId: String) -> String {
        "minidisc.mood.playlistId.\(mood.rawValue).\(serverId)"
    }
    private static func lastAttemptKey(_ serverId: String) -> String {
        "minidisc.mood.lastAttempt.\(serverId)"
    }
    private static func lastSourceKey(_ serverId: String) -> String {
        "minidisc.mood.lastSource.\(serverId)"
    }
    private static func coverKey(_ mood: Mood, _ serverId: String) -> String {
        "minidisc.mood.coverApplied.v2.\(mood.rawValue).\(serverId)"
    }

    func syncedCycle(mood: Mood, serverId: String) -> Date? {
        let raw = userDefaults.double(forKey: Self.cycleKey(mood, serverId))
        return raw == 0 ? nil : Date(timeIntervalSinceReferenceDate: raw)
    }

    func setSyncedCycle(_ date: Date, mood: Mood, serverId: String) {
        userDefaults.set(date.timeIntervalSinceReferenceDate, forKey: Self.cycleKey(mood, serverId))
    }

    func lastRefresh(serverId: String) -> Date? {
        Mood.allCases.compactMap { syncedCycle(mood: $0, serverId: serverId) }.max()
    }

    func playlistId(mood: Mood, serverId: String) -> String? {
        userDefaults.string(forKey: Self.playlistIdKey(mood, serverId))
    }

    func setPlaylistId(_ id: String, mood: Mood, serverId: String) {
        userDefaults.set(id, forKey: Self.playlistIdKey(mood, serverId))
    }

    func lastAttempt(serverId: String) -> Date? {
        let raw = userDefaults.double(forKey: Self.lastAttemptKey(serverId))
        return raw == 0 ? nil : Date(timeIntervalSinceReferenceDate: raw)
    }

    func setLastAttempt(_ date: Date, serverId: String) {
        userDefaults.set(date.timeIntervalSinceReferenceDate, forKey: Self.lastAttemptKey(serverId))
    }

    func hasCover(mood: Mood, serverId: String) -> Bool {
        userDefaults.bool(forKey: Self.coverKey(mood, serverId))
    }

    func setHasCover(mood: Mood, serverId: String) {
        userDefaults.set(true, forKey: Self.coverKey(mood, serverId))
    }

    func lastSource(serverId: String) -> MoodSourceKind? {
        userDefaults.string(forKey: Self.lastSourceKey(serverId)).flatMap(MoodSourceKind.init(rawValue:))
    }

    func setLastSource(_ kind: MoodSourceKind, serverId: String) {
        userDefaults.set(kind.rawValue, forKey: Self.lastSourceKey(serverId))
    }

    func markAllDue(serverId: String) {
        for mood in Mood.allCases {
            userDefaults.removeObject(forKey: Self.cycleKey(mood, serverId))
        }
        userDefaults.removeObject(forKey: Self.lastAttemptKey(serverId))
    }

    func reset(serverId: String) {
        for mood in Mood.allCases {
            userDefaults.removeObject(forKey: Self.cycleKey(mood, serverId))
            userDefaults.removeObject(forKey: Self.playlistIdKey(mood, serverId))
            userDefaults.removeObject(forKey: Self.coverKey(mood, serverId))
        }
        userDefaults.removeObject(forKey: Self.lastAttemptKey(serverId))
        userDefaults.removeObject(forKey: Self.lastSourceKey(serverId))
    }
}
