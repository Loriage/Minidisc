// Minidisc — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

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

    var qualityName: String? { quality?.quality?.name }

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

    /// True when Lidarr downloaded the release but could not import it on its own.
    var needsManualImport: Bool {
        downloadId != nil
            && trackedDownloadStatus == "warning"
            && (trackedDownloadState == "importPending" || trackedDownloadState == "importBlocked")
    }

    var hasIssue: Bool {
        status == "warning" || trackedDownloadStatus == "warning" || trackedDownloadStatus == "error"
    }

    var statusLabel: String {
        if status == "completed" {
            switch trackedDownloadState {
            case "importPending" where trackedDownloadStatus == "warning": return String(localized: "Import blocked")
            case "importPending": return String(localized: "Import pending")
            case "importBlocked":  return String(localized: "Import blocked")
            case "importing":      return String(localized: "Importing")
            default:               return String(localized: "Downloading")
            }
        }
        switch status {
        case "queued", "delay", "downloadClientUnavailable": return String(localized: "Queued")
        case "paused":      return String(localized: "Paused")
        case "failed":      return String(localized: "Failed")
        case "warning":     return String(localized: "Warning")
        case "downloading": return String(localized: "Downloading")
        default:            return String(localized: "Downloading")
        }
    }

    /// The reasons Lidarr attached to a blocked import, flattened.
    var messages: [String] {
        (statusMessages ?? []).flatMap { message -> [String] in
            var lines = message.messages
            if let title = message.title, !title.isEmpty, !lines.contains(title) { lines.insert(title, at: 0) }
            return lines
        }
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
