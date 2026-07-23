// Minidisc — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

// MARK: - Raw JSON passthrough

/// A JSON value decoded and re-encoded verbatim. Used to round-trip Lidarr's `quality` object into the
/// manual-import command without modelling every field, so nothing Lidarr needs is dropped.
nonisolated enum LidarrRawJSON: Codable, Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([LidarrRawJSON])
    case object([String: LidarrRawJSON])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([LidarrRawJSON].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: LidarrRawJSON].self) {
            self = .object(value)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:            try container.encodeNil()
        case .bool(let v):     try container.encode(v)
        case .int(let v):      try container.encode(v)
        case .double(let v):   try container.encode(v)
        case .string(let v):   try container.encode(v)
        case .array(let v):    try container.encode(v)
        case .object(let v):   try container.encode(v)
        }
    }
}

// MARK: - Manual import candidates

/// A file Lidarr found in a completed download, with the artist, album, and tracks it guessed from the
/// tags (`GET /api/v1/manualimport`).
nonisolated struct LidarrManualImportFile: Decodable, Sendable, Identifiable {
    let id: Int
    let path: String
    let name: String?
    let size: Int64?
    let quality: LidarrRawJSON?
    let releaseGroup: String?
    let downloadId: String?
    let artist: LidarrArtistRef?
    let album: LidarrAlbumRef?
    let albumReleaseId: Int?
    let tracks: [LidarrManualImportTrack]?
    let rejections: [LidarrRejection]?

    var qualityName: String? {
        if case let .object(fields)? = quality,
           case let .object(inner)? = fields["quality"],
           case let .string(name)? = inner["name"] {
            return name
        }
        return nil
    }

    var reasons: [String] { (rejections ?? []).compactMap(\.reason) }

    /// Lidarr can only import a file it matched to an artist, album, and at least one track.
    var isImportable: Bool {
        artist != nil && album != nil && !(tracks ?? []).isEmpty
    }

    var displayName: String {
        if let name, !name.isEmpty { return name }
        return (path as NSString).lastPathComponent
    }
}

nonisolated struct LidarrManualImportTrack: Decodable, Sendable, Identifiable, Hashable {
    let id: Int
    let title: String?
    let trackNumber: String?
    let mediumNumber: Int?
}

nonisolated struct LidarrRejection: Decodable, Sendable {
    let reason: String?
}

// MARK: - Manual import command

/// Body of `POST /api/v1/command` for `ManualImport`.
nonisolated struct LidarrManualImportCommand: Encodable, Sendable {
    let name = "ManualImport"
    let importMode = "auto"
    let files: [LidarrManualImportFileRequest]
}

/// One file to import, mapped to its artist, album, release, and tracks.
nonisolated struct LidarrManualImportFileRequest: Encodable, Sendable {
    let path: String
    let artistId: Int
    let albumId: Int
    let albumReleaseId: Int?
    let trackIds: [Int]
    let quality: LidarrRawJSON?
    let releaseGroup: String?
    let downloadId: String?
    let disableReleaseSwitching = false

    init?(file: LidarrManualImportFile) {
        guard let artistId = file.artist?.id, let albumId = file.album?.id else { return nil }
        let trackIds = (file.tracks ?? []).map(\.id)
        guard !trackIds.isEmpty else { return nil }
        self.path = file.path
        self.artistId = artistId
        self.albumId = albumId
        self.albumReleaseId = file.albumReleaseId
        self.trackIds = trackIds
        self.quality = file.quality
        self.releaseGroup = file.releaseGroup
        self.downloadId = file.downloadId
    }
}
