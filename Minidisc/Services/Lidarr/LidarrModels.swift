import Foundation

/// A result of `GET /api/v1/artist/lookup`. Only the fields the add flow needs are decoded.
nonisolated struct LidarrArtistLookup: Decodable, Sendable, Identifiable {
    /// MusicBrainz id. The stable identity of a lookup result and the key Lidarr adds by.
    let foreignArtistId: String
    let artistName: String
    let disambiguation: String?
    let overview: String?
    /// Lidarr's own artist id, present only when the artist is already in the library.
    let existingId: Int?
    let remotePoster: String?
    let images: [LidarrImage]?

    var id: String { foreignArtistId }
    var isAlreadyAdded: Bool { existingId != nil }

    var posterURL: URL? {
        if let remotePoster, let url = URL(string: remotePoster) { return url }
        let poster = images?.first { $0.coverType == "poster" }
        if let remote = poster?.remoteUrl, let url = URL(string: remote) { return url }
        return nil
    }

    enum CodingKeys: String, CodingKey {
        case foreignArtistId, artistName, disambiguation, overview, remotePoster, images
        case existingId = "id"
    }
}

nonisolated struct LidarrImage: Decodable, Sendable, Hashable {
    let coverType: String?
    let remoteUrl: String?
    let url: String?
}

// Prefer square-friendly image types before wide banners or fanart.
private nonisolated let lidarrSquarishCoverTypes = ["poster", "cover", "headshot", "disc"]

/// The best image path for a cover type: an absolute external URL when Lidarr has one, otherwise the
/// instance-local path (e.g. `/MediaCover/…`) that `LidarrClient.imageData(forPath:)` resolves with auth.
nonisolated func lidarrImagePath(from images: [LidarrImage]?, coverType: String = "poster") -> String? {
    guard let images else { return nil }
    let preferred = [coverType] + lidarrSquarishCoverTypes.filter { $0 != coverType }
    let img = preferred.lazy.compactMap { type in images.first { $0.coverType == type } }.first
        ?? images.first
    guard let img else { return nil }
    if let remote = img.remoteUrl, remote.hasPrefix("http") { return remote }
    if let local = img.url, !local.isEmpty { return local }
    if let remote = img.remoteUrl, !remote.isEmpty { return remote }
    return nil
}

nonisolated struct LidarrStatistics: Decodable, Sendable, Hashable {
    let albumCount: Int?
    let trackFileCount: Int?
    let totalTrackCount: Int?
}

/// An artist Lidarr manages (`GET /api/v1/artist`).
nonisolated struct LidarrArtist: Decodable, Sendable, Identifiable, Hashable {
    let id: Int
    let artistName: String
    let foreignArtistId: String?
    let overview: String?
    let monitored: Bool
    let images: [LidarrImage]?
    let statistics: LidarrStatistics?

    var posterPath: String? { lidarrImagePath(from: images) }
    var musicBrainzURL: URL? {
        guard let foreignArtistId, !foreignArtistId.isEmpty else { return nil }
        return URL(string: "https://musicbrainz.org/artist/\(foreignArtistId)")
    }
}

/// One physical or digital medium of an album (a disc), from `LidarrAlbum.media`.
nonisolated struct LidarrMedium: Decodable, Sendable, Hashable {
    let mediumNumber: Int
    let mediumName: String?
    let mediumFormat: String?
}

/// A single track of an album (`GET /api/v1/track`).
nonisolated struct LidarrTrack: Decodable, Sendable, Identifiable {
    let id: Int
    let title: String
    let trackNumber: String?
    let duration: Int?
    let hasFile: Bool
    let mediumNumber: Int?

    var durationText: String? {
        guard let duration, duration > 0 else { return nil }
        let seconds = duration / 1000
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// An album of a managed artist (`GET /api/v1/album`).
nonisolated struct LidarrAlbum: Decodable, Sendable, Identifiable, Hashable {
    let id: Int
    let artistId: Int?
    let title: String
    /// "Album", "EP", "Single", "Broadcast", or "Other".
    let albumType: String?
    var monitored: Bool
    let releaseDate: String?
    let images: [LidarrImage]?
    let statistics: LidarrStatistics?
    let media: [LidarrMedium]?

    var coverPath: String? { lidarrImagePath(from: images) }
    func mediumTitle(for number: Int) -> String {
        let medium = media?.first { $0.mediumNumber == number }
        if let name = medium?.mediumName, !name.isEmpty { return name }
        if let format = medium?.mediumFormat, !format.isEmpty {
            return (media?.count ?? 1) > 1 ? "\(format) \(number)" : format
        }
        return "Disc \(number)"
    }
    var year: String? {
        guard let releaseDate, releaseDate.count >= 4 else { return nil }
        return String(releaseDate.prefix(4))
    }
    var trackProgress: String? {
        guard let have = statistics?.trackFileCount, let total = statistics?.totalTrackCount, total > 0 else { return nil }
        return "\(have)/\(total)"
    }
}

/// Body of `POST /api/v1/command` for triggering an artist command (search, refresh).
nonisolated struct LidarrCommand: Encodable, Sendable {
    let name: String
    let artistId: Int
}

/// Body of `PUT /api/v1/album/monitor` for toggling album monitoring.
nonisolated struct LidarrAlbumMonitorRequest: Encodable, Sendable {
    let albumIds: [Int]
    let monitored: Bool
}

/// Body of `POST /api/v1/command` for searching specific albums.
nonisolated struct LidarrAlbumSearchCommand: Encodable, Sendable {
    let name: String
    let albumIds: [Int]
}

/// One release found by an indexer (`GET /api/v1/release`).
nonisolated struct LidarrRelease: Decodable, Sendable, Identifiable {
    let guid: String
    let title: String
    let size: Int64?
    let seeders: Int?
    let leechers: Int?
    let indexer: String?
    let indexerId: Int?
    /// Set by Lidarr when it could map the release to a library artist/album during the search.
    let albumId: Int?
    let artistId: Int?
    /// Age in days.
    let age: Int?
    let quality: LidarrQualityInfo?
    let rejected: Bool?
    let rejections: [String]?
    let downloadAllowed: Bool?
    let downloadProtocol: String?
    /// Indexer flags such as "Freeleech", "Scene". Lidarr sends either names or a bitmask number.
    let indexerFlags: LidarrIndexerFlags?
    let infoUrl: String?
    let publishDate: String?

    var id: String { guid }
    var qualityName: String? { quality?.quality?.name }
    var isTorrent: Bool { (downloadProtocol ?? "").lowercased() == "torrent" }
    var isRejected: Bool { rejected == true || downloadAllowed == false }
    var flags: [String] { indexerFlags?.names ?? [] }
    var isFreeleech: Bool { flags.contains { $0.localizedCaseInsensitiveContains("freeleech") } }
    /// The original release, i.e. not a repack, proper, or re-rip.
    var isOriginal: Bool {
        let lower = title.lowercased()
        return !lower.contains("repack") && !lower.contains("proper") && !lower.contains("rerip")
    }
    var infoURL: URL? {
        guard let infoUrl, let url = URL(string: infoUrl) else { return nil }
        return url
    }
    var flagLabel: String? {
        let lower = title.lowercased()
        var flags: [String] = []
        if lower.contains("proper") { flags.append("PROPER") }
        if lower.contains("repack") { flags.append("REPACK") }
        return flags.isEmpty ? nil : flags.joined(separator: " ")
    }

    enum CodingKeys: String, CodingKey {
        case guid, title, size, seeders, leechers, indexer, indexerId, albumId, artistId, age, quality, rejected, rejections, downloadAllowed, indexerFlags, infoUrl, publishDate
        case downloadProtocol = "protocol"
    }
}

/// Indexer flags, decoded from either an array of names or a bitmask integer (Lidarr sends both,
/// depending on version). Exposes clean display names.
nonisolated struct LidarrIndexerFlags: Decodable, Sendable, Hashable {
    let names: [String]

    private static let bitmask: [(Int, String)] = [
        (1, "Freeleech"),
        (2, "Halfleech"),
        (4, "Double Upload"),
        (8, "Freeleech 75%"),
        (16, "Freeleech 25%"),
        (32, "Scene"),
        (64, "Nuked"),
    ]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let strings = try? container.decode([String].self) {
            names = strings
        } else if let bits = try? container.decode(Int.self) {
            names = Self.bitmask.compactMap { bits & $0.0 != 0 ? $0.1 : nil }
        } else {
            names = []
        }
    }
}

nonisolated struct LidarrQualityInfo: Decodable, Sendable {
    let quality: LidarrQualityName?
}

nonisolated struct LidarrQualityName: Decodable, Sendable {
    let name: String?
}

/// Grab request; optional album/artist IDs force the target of an unparsed release.
nonisolated struct LidarrGrabRequest: Encodable, Sendable {
    let guid: String
    let indexerId: Int
    var albumId: Int?
    var artistId: Int?
}

nonisolated struct LidarrProfile: Decodable, Sendable, Identifiable {
    let id: Int
    let name: String
}

nonisolated struct LidarrRootFolder: Decodable, Sendable, Identifiable {
    let id: Int
    let path: String
    let freeSpace: Int64?
}

nonisolated enum LidarrMonitorOption: String, CaseIterable, Identifiable, Sendable {
    case all
    case future
    case none

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all:    return "All albums"
        case .future: return "Future albums"
        case .none:   return "None"
        }
    }
}

/// Body of `POST /api/v1/artist`. The minimal set of fields Lidarr needs to add and manage an artist.
nonisolated struct LidarrAddArtistRequest: Encodable, Sendable {
    let foreignArtistId: String
    let artistName: String
    let qualityProfileId: Int
    let metadataProfileId: Int
    let rootFolderPath: String
    let monitored: Bool
    let monitorNewItems: String
    let addOptions: AddOptions

    nonisolated struct AddOptions: Encodable, Sendable {
        let monitor: String
        let searchForMissingAlbums: Bool
    }

    init(
        artist: LidarrArtistLookup,
        qualityProfileId: Int,
        metadataProfileId: Int,
        rootFolderPath: String,
        monitor: LidarrMonitorOption,
        searchForMissingAlbums: Bool
    ) {
        self.foreignArtistId = artist.foreignArtistId
        self.artistName = artist.artistName
        self.qualityProfileId = qualityProfileId
        self.metadataProfileId = metadataProfileId
        self.rootFolderPath = rootFolderPath
        self.monitored = monitor != .none
        self.monitorNewItems = monitor == .all ? "all" : "none"
        self.addOptions = AddOptions(monitor: monitor.rawValue, searchForMissingAlbums: searchForMissingAlbums)
    }
}
