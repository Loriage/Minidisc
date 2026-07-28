import Foundation

// MARK: - Shared refs

/// A lenient artist reference embedded in queue and manual-import payloads.
nonisolated struct LidarrArtistRef: Decodable, Sendable, Hashable {
    let id: Int
    let artistName: String?
}

/// A lenient album reference embedded in queue and manual-import payloads.
nonisolated struct LidarrAlbumRef: Decodable, Sendable, Hashable {
    let id: Int
    let title: String?
}

// MARK: - Queue

/// One page of `GET /api/v1/queue`.
nonisolated struct LidarrQueueResponse: Decodable, Sendable {
    let records: [LidarrQueueItem]
}

/// What a queue item is doing, resolved from the three fields Lidarr uses to describe one: the download
/// client's `status`, and — once that reports `completed` — the `trackedDownloadState` and
/// `trackedDownloadStatus` pair saying what Lidarr then made of the files.
///
/// Lidarr spells two of its tracked states differently from Sonarr and Radarr (`downloadFailed` and
/// `importFailed`, where they say `failed`), so the raw values matched here are Lidarr's own:
/// `DownloadItemStatus` and `PendingReleaseReason` for the first field, `TrackedDownloadState` for the
/// second.
nonisolated enum LidarrQueueState: Sendable, Hashable {
    /// Waiting on the download client, on a delay profile, or on a fallback to another indexer.
    case queued
    case paused
    case downloading
    /// The transfer failed, or failed and is waiting for Lidarr to act on it.
    case downloadFailed
    case importPending
    case importing
    /// Downloaded, but Lidarr will not import it on its own — this is what manual import is for.
    case importBlocked
    case importFailed
    case imported
    case ignored
    /// The download client itself reported a problem, such as a stalled transfer.
    case warning
    /// A value a newer Lidarr introduced, which this app does not know yet.
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

    /// True when the state is one the user has to deal with.
    var isProblem: Bool {
        switch self {
        case .downloadFailed, .importBlocked, .importFailed, .warning: return true
        default: return false
        }
    }
}

/// A download Lidarr is tracking. Status/state are kept as raw strings so an unfamiliar value from a
/// newer Lidarr never fails the whole decode.
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

    /// Total size in bytes, for the detail sheet. Lidarr sends it as a JSON number.
    var totalSize: Int64? {
        guard let size, size > 0 else { return nil }
        return Int64(size)
    }

    /// When Lidarr added the download, parsed from its ISO-8601 timestamp (with or without fractional
    /// seconds, both of which Lidarr sends depending on the version).
    var addedDate: Date? {
        guard let added, !added.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: added) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: added)
    }

    /// The remaining time as a localized, abbreviated duration ("2h 14m"), from Lidarr's .NET timespan
    /// (`[d.]hh:mm:ss[.fffffff]`).
    var timeRemaining: String? {
        guard let timeleft, !timeleft.isEmpty else { return nil }
        var body = Substring(timeleft)
        var days = 0
        // A leading `d.` is a day count; a trailing `.fffffff` is fractional seconds, and is dropped.
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

    /// Fraction downloaded, 0...1.
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

    /// What Lidarr is doing with this download. Until the download client reports `completed`, its own
    /// status is the whole story; after that, what matters is the tracked state Lidarr moved it to.
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
        // Older Lidarr parks a blocked import in `importPending` and flags it with a warning instead.
        case "importPending" where trackedDownloadStatus == "warning": return .importBlocked
        case "importPending":                          return .importPending
        case "importBlocked":                          return .importBlocked
        case "importFailed":                           return .importFailed
        case "importing":                              return .importing
        case "imported":                               return .imported
        case "downloadFailed", "downloadFailedPending": return .downloadFailed
        case "ignored":                                return .ignored
        // A download the client finished but Lidarr has not picked up yet stays in its downloading state.
        default:                                       return .downloading
        }
    }

    /// True when Lidarr downloaded the release but will not import it on its own, so the user has to.
    var needsManualImport: Bool {
        guard downloadId != nil else { return false }
        return state == .importBlocked || state == .importFailed
    }

    /// True when the files are on disk, so asking Lidarr for import candidates can return something.
    /// Broader than `needsManualImport`: a download Lidarr is still deciding about can also be imported
    /// by hand, while one it already imported or was told to ignore has nothing left to offer.
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

    /// The reasons Lidarr attached to a blocked import, flattened.
    var messages: [String] {
        (statusMessages ?? []).flatMap { message -> [String] in
            var lines = message.messages
            if let title = message.title, !title.isEmpty, !lines.contains(title) { lines.insert(title, at: 0) }
            return lines
        }
    }

    /// Every reason Lidarr gave for the current state, error first, for the detail sheet to list.
    var allMessages: [String] {
        var all = messages
        if let errorMessage, !errorMessage.isEmpty, !all.contains(errorMessage) {
            all.insert(errorMessage, at: 0)
        }
        return all
    }

    /// A one-line reason for an issue (stalled download, blocked import), for the row to show.
    var issueDetail: String? {
        if let errorMessage, !errorMessage.isEmpty { return errorMessage }
        return (statusMessages ?? []).flatMap(\.messages).first
    }
}

nonisolated struct LidarrQueueStatusMessage: Decodable, Sendable, Hashable {
    let title: String?
    let messages: [String]
}
