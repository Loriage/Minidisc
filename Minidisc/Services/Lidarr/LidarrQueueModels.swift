import Foundation

nonisolated struct LidarrArtistRef: Decodable, Sendable, Hashable {
    let id: Int
    let artistName: String?
}

nonisolated struct LidarrAlbumRef: Decodable, Sendable, Hashable {
    let id: Int
    let title: String?
}

nonisolated struct LidarrQueueResponse: Decodable, Sendable {
    let records: [LidarrQueueItem]
}

nonisolated enum LidarrQueueState: Sendable, Hashable {
    case queued
    case paused
    case downloading
    case downloadFailed
    case importPending
    case importing
    case importBlocked
    case importFailed
    case imported
    case ignored
    case warning
    case unknown

    var label: String {
        switch self {
        case .queued:         return String(localized: "Queued")
        case .paused:         return String(localized: "Paused")
        case .downloading:    return String(localized: "Downloading")
        case .downloadFailed: return String(localized: "Download failed")
        case .importPending:  return String(localized: "Import pending")
        case .importing:      return String(localized: "Importing")
        case .importBlocked:  return String(localized: "Import blocked")
        case .importFailed:   return String(localized: "Import failed")
        case .imported:       return String(localized: "Imported")
        case .ignored:        return String(localized: "Ignored")
        case .warning:        return String(localized: "Warning")
        case .unknown:        return String(localized: "Unknown")
        }
    }

    var isProblem: Bool {
        switch self {
        case .downloadFailed, .importBlocked, .importFailed, .warning: return true
        default: return false
        }
    }
}

nonisolated struct LidarrQueueItem: Decodable, Sendable, Identifiable {
    let id: Int
    let downloadId: String?
    let title: String?
    let artistId: Int?
    let albumId: Int?
    let artist: LidarrArtistRef?
    let album: LidarrAlbumRef?
    let status: String?
    let trackedDownloadStatus: String?
    let trackedDownloadState: String?
    let statusMessages: [LidarrQueueStatusMessage]?
    let errorMessage: String?
    let size: Double?
    let sizeleft: Double?
    let timeleft: String?
    let quality: LidarrQualityInfo?
    let indexer: String?
    let downloadClient: String?
    let `protocol`: String?
    let added: String?

    var qualityName: String? { quality?.quality?.name }

    var totalSize: Int64? {
        guard let size, size > 0 else { return nil }
        return Int64(size)
    }

    var addedDate: Date? {
        guard let added, !added.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: added) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: added)
    }

    var timeRemaining: String? {
        guard let timeleft, !timeleft.isEmpty else { return nil }
        var body = Substring(timeleft)
        var days = 0
        if let dot = body.firstIndex(of: "."), let colon = body.firstIndex(of: ":"), dot < colon,
           let parsed = Int(body[..<dot]) {
            days = parsed
            body = body[body.index(after: dot)...]
        }
        let fields = body.split(separator: ":").map { $0.prefix { $0.isNumber } }.compactMap { Int($0) }
        guard fields.count >= 3 else { return nil }
        let total = (days * 86_400) + (fields[0] * 3600) + (fields[1] * 60) + fields[2]
        guard total > 0 else { return nil }
        return Duration.seconds(total).formatted(
            .units(allowed: [.days, .hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2)
        )
    }

    var progress: Double {
        guard let size, size > 0, let sizeleft else { return status == "completed" ? 1 : 0 }
        return max(0, min(1, (size - sizeleft) / size))
    }

    var displayTitle: String {
        switch (artist?.artistName, album?.title) {
        case let (name?, albumTitle?): return "\(name) — \(albumTitle)"
        case let (name?, nil):         return name
        case let (nil, albumTitle?):   return albumTitle
        default:                       return title ?? String(localized: "Unknown")
        }
    }

    var state: LidarrQueueState {
        guard let status else { return .unknown }
        guard status == "completed" else {
            switch status {
            case "queued", "delay", "downloadClientUnavailable", "fallback": return .queued
            case "paused":      return .paused
            case "downloading": return .downloading
            case "failed":      return .downloadFailed
            case "warning":     return .warning
            default:            return .unknown
            }
        }
        switch trackedDownloadState {
        case "importPending" where trackedDownloadStatus == "warning": return .importBlocked
        case "importPending":                          return .importPending
        case "importBlocked":                          return .importBlocked
        case "importFailed":                           return .importFailed
        case "importing":                              return .importing
        case "imported":                               return .imported
        case "downloadFailed", "downloadFailedPending": return .downloadFailed
        case "ignored":                                return .ignored
        default:                                       return .downloading
        }
    }

    var needsManualImport: Bool {
        guard downloadId != nil else { return false }
        return state == .importBlocked || state == .importFailed
    }

    var canManuallyImport: Bool {
        guard downloadId != nil, status == "completed" else { return false }
        switch state {
        case .imported, .ignored, .downloadFailed: return false
        default: return true
        }
    }

    var hasIssue: Bool {
        state.isProblem || trackedDownloadStatus == "warning" || trackedDownloadStatus == "error"
    }

    var statusLabel: String { state.label }

    var messages: [String] {
        (statusMessages ?? []).flatMap { message -> [String] in
            var lines = message.messages
            if let title = message.title, !title.isEmpty, !lines.contains(title) { lines.insert(title, at: 0) }
            return lines
        }
    }

    var allMessages: [String] {
        var all = messages
        if let errorMessage, !errorMessage.isEmpty, !all.contains(errorMessage) {
            all.insert(errorMessage, at: 0)
        }
        return all
    }

    var issueDetail: String? {
        if let errorMessage, !errorMessage.isEmpty { return errorMessage }
        return (statusMessages ?? []).flatMap(\.messages).first
    }
}

nonisolated struct LidarrQueueStatusMessage: Decodable, Sendable, Hashable {
    let title: String?
    let messages: [String]
}
