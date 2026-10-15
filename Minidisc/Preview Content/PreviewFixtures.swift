#if DEBUG
import SwiftUI
import SwiftData
import SwiftSonic
import UIKit

// Mock library, fake services and an in-memory AppContainer for SwiftUI Previews.
// Nothing here talks to a server: every cover ID uses the "local:" prefix so ArtworkImageCache
// resolves it through `localArtworkProvider`, which these previews replace with generated artwork.

// MARK: - Mock catalogue

nonisolated enum PreviewFixtures {
    static let noraVale = artist(id: "ar-nora", name: "Nora Vale")
    static let quietKites = artist(id: "ar-kites", name: "The Quiet Kites")
    static let mossAndCopper = artist(id: "ar-moss", name: "Moss & Copper")
    static let hanaOkafor = artist(id: "ar-hana", name: "Hana Okafor")
    static let deltaSleepClub = artist(id: "ar-delta", name: "Delta Sleep Club")
    static let ivoLindqvistTrio = artist(id: "ar-ivo", name: "Ivo Lindqvist Trio")
    /// Credit-only: guests on other artists' albums and has none filed under it.
    static let harbourStrings = artist(id: "ar-strings", name: "Harbour String Quartet")

    static let tidalRooms = album(
        id: "al-tidal", name: "Tidal Rooms", artist: noraVale, year: 2023, genre: "Indie Pop",
        releaseDate: ItemDate(year: 2023, month: 4, day: 14), label: "Harbour Light Records",
        guests: [1: hanaOkafor, 7: quietKites, 8: harbourStrings],
        tracks: [
            ("Undertow", 222), ("Salt in the Static", 245), ("Glass Harbour", 198),
            ("Lighthouse Keeper", 267), ("The Long Way Round", 236), ("Small Hours", 178),
            ("Driftwood Hymn", 284), ("Kites Over Kelp Street", 213), ("Ebb", 112), ("Tidal Rooms", 321),
        ]
    )
    static let paperLanterns = album(
        id: "al-lanterns", name: "Paper Lanterns", artist: noraVale, year: 2020, genre: "Indie Pop",
        guests: [2: harbourStrings],
        tracks: [
            ("Paper Lanterns", 241), ("Fold", 198), ("Winter Orchard", 263), ("Postcards from Ys", 225),
            ("Quiet Engine", 207), ("Saltwater Letters", 284), ("Ferris", 176),
            ("All the Small Lights", 302), ("Home Before Dark", 239),
        ]
    )
    static let lowTide = album(
        id: "al-lowtide", name: "Low Tide", artist: noraVale, year: 2021, genre: "Indie Pop",
        releaseTypes: ["EP"],
        tracks: [("Low Tide", 213), ("Shoreline (Demo)", 187), ("Moon Pull", 244), ("Undertow (Acoustic)", 229)]
    )
    static let glasshouse = album(
        id: "al-glasshouse", name: "Glasshouse", artist: noraVale, year: 2024, genre: "Indie Pop",
        releaseTypes: ["Single"], tracks: [("Glasshouse", 201)]
    )
    static let northernStatic = album(
        id: "al-static", name: "Northern Static", artist: quietKites, year: 2022, genre: "Dream Pop",
        tracks: [
            ("Aurora Signal", 268), ("Frost Radio", 233), ("Polar Drift", 291), ("Snowblind", 214),
            ("Hum", 189), ("Northern Static", 336), ("Long Night Drive", 257), ("Ice Choir", 245),
        ]
    )
    static let fieldRecordings = album(
        id: "al-field", name: "Field Recordings, Vol. 2", artist: mossAndCopper, year: 2019, genre: "Folk",
        label: "Fellside", secondDiscStart: 4,
        tracks: [
            ("Hedgerow", 182), ("The Miller’s Daughter", 254), ("Rain on Slate", 207), ("Copper Kettle", 168),
            ("Over the Fell", 239), ("Lantern Walk", 221), ("Old Stone Bridge", 276),
        ]
    )
    static let midnightTransit = album(
        id: "al-transit", name: "Midnight Transit", artist: hanaOkafor, year: 2024, genre: "Neo-Soul",
        tracks: [
            ("Last Train", 247), ("Velvet Hours", 233), ("City Glow", 219), ("Northbound", 262),
            ("Platform 9", 198), ("Slow Burn", 281), ("Midnight Transit", 305), ("Morning Comes", 244),
        ]
    )
    static let neonHarbour = album(
        id: "al-harbour", name: "Neon Harbour", artist: deltaSleepClub, year: 2021, genre: "Electronic",
        tracks: [
            ("Neon Harbour", 312), ("Pulse Lines", 274), ("Container Ships", 296),
            ("Afterglow", 251), ("Static Bloom", 238), ("Low Light", 269),
        ]
    )
    static let blueHourSessions = album(
        id: "al-bluehour", name: "Blue Hour Sessions", artist: ivoLindqvistTrio, year: 2018, genre: "Jazz",
        tracks: [
            ("Blue Hour", 384), ("Brushes & Rain", 342), ("Kind of Late", 415),
            ("Steam Room Waltz", 298), ("Lindqvist’s Lament", 451), ("Coda in F", 267),
        ]
    )

    static let albums: [AlbumID3] = [
        tidalRooms, paperLanterns, lowTide, glasshouse, northernStatic,
        fieldRecordings, midnightTransit, neonHarbour, blueHourSessions,
    ]
    static let artists: [ArtistID3] = [
        noraVale, quietKites, mossAndCopper, hanaOkafor, deltaSleepClub, ivoLindqvistTrio, harbourStrings,
    ]

    static let recentlyAdded = [glasshouse, midnightTransit, tidalRooms, neonHarbour, northernStatic]
    static let recentlyPlayed = [tidalRooms, blueHourSessions, midnightTransit, fieldRecordings]
    static let mostPlayed = [tidalRooms, northernStatic, paperLanterns, neonHarbour, blueHourSessions, fieldRecordings]

    static let starredSongs: [Song] = [
        songs(of: tidalRooms)[1], songs(of: tidalRooms)[3], songs(of: midnightTransit)[1],
        songs(of: northernStatic)[0], songs(of: neonHarbour)[0], songs(of: blueHourSessions)[0],
        songs(of: paperLanterns)[7],
    ]
    static let starredAlbums = [northernStatic, blueHourSessions, midnightTransit]
    static let starredArtists = [quietKites, hanaOkafor]

    static let playlists: [PlaylistWithSongs] = [
        playlist(id: "pl-commute", name: "Morning Commute", hoursAgo: 2, songs: [
            songs(of: tidalRooms)[0], songs(of: midnightTransit)[2], songs(of: northernStatic)[1],
            songs(of: neonHarbour)[1], songs(of: glasshouse)[0], songs(of: paperLanterns)[1],
            songs(of: midnightTransit)[3], songs(of: fieldRecordings)[3], songs(of: tidalRooms)[7],
            songs(of: northernStatic)[6], songs(of: neonHarbour)[3], songs(of: midnightTransit)[7],
        ]),
        playlist(id: "pl-jazz", name: "Late Night Jazz", hoursAgo: 26, songs: songs(of: blueHourSessions)
            + [songs(of: midnightTransit)[5], songs(of: midnightTransit)[1]]),
        playlist(id: "pl-run", name: "Running Mix", hoursAgo: 72, songs: songs(of: neonHarbour)
            + [songs(of: northernStatic)[0], songs(of: northernStatic)[2], songs(of: midnightTransit)[2]]),
        playlist(id: "pl-rainy", name: "Rainy Sunday", hoursAgo: 240, songs: songs(of: fieldRecordings)
            + [songs(of: paperLanterns)[2], songs(of: tidalRooms)[5], songs(of: lowTide)[1]]),
    ]

    static let noraBiography = """
        Nora Vale is a singer-songwriter from Bergen, Norway, whose hushed indie pop draws on the \
        harbour town she grew up in. After self-releasing Paper Lanterns in 2020, she recorded Tidal \
        Rooms in a converted boathouse over a single winter, pairing close-miked vocals with tape \
        loops and field recordings of the sea. <a href="https://www.last.fm/music/Nora+Vale">Read more on Last.fm</a>
        """

    /// The player queue: Tidal Rooms in order, with the third track playing.
    static var queue: [DisplayableSong] { songs(of: tidalRooms).map { DisplayableSong(from: $0) } }

    static func songs(of album: AlbumID3) -> [Song] { album.song ?? [] }

    static func album(id: String) -> AlbumID3? { albums.first { $0.id == id } }

    static func artistWithAlbums(id: String) -> ArtistID3? {
        guard let artist = artists.first(where: { $0.id == id }) else { return nil }
        let releases = albums.filter { $0.artistId == id }.map(withoutSongs)
        return ArtistID3(id: artist.id, name: artist.name, albumCount: releases.count,
                         coverArt: artist.coverArt, album: releases)
    }

    /// Browsing responses (artist pages, shelves) carry album headers without their track lists.
    static func withoutSongs(_ album: AlbumID3) -> AlbumID3 {
        AlbumID3(
            id: album.id, name: album.name, songCount: album.songCount, duration: album.duration,
            artist: album.artist, artistId: album.artistId, coverArt: album.coverArt,
            year: album.year, genre: album.genre, releaseTypes: album.releaseTypes
        )
    }

    // MARK: Builders

    private static func artist(id: String, name: String) -> ArtistID3 {
        ArtistID3(id: id, name: name, coverArt: "local:preview-\(id)")
    }

    private static func album(
        id: String,
        name: String,
        artist: ArtistID3,
        year: Int,
        genre: String,
        releaseTypes: [String] = ["Album"],
        releaseDate: ItemDate? = nil,
        label: String? = nil,
        guests: [Int: ArtistID3] = [:],
        secondDiscStart: Int? = nil,
        tracks: [(title: String, seconds: Int)]
    ) -> AlbumID3 {
        let coverArt = "local:preview-\(id)"
        let songs = tracks.enumerated().map { index, track in
            let credits = [artist] + [guests[index]].compactMap { $0 }
            let isSecondDisc = secondDiscStart.map { index >= $0 } ?? false
            return Song(
                id: "\(id)-\(index + 1)", title: track.title, album: name,
                artist: credits.map(\.name).joined(separator: ", "),
                track: isSecondDisc ? index - (secondDiscStart ?? 0) + 1 : index + 1,
                year: year, genre: genre, coverArt: coverArt,
                contentType: "audio/flac", suffix: "flac", duration: track.seconds, bitRate: 1_011,
                discNumber: isSecondDisc ? 2 : 1, albumId: id, artistId: artist.id,
                artists: credits, albumArtists: [artist],
                bitDepth: 24, samplingRate: 48_000, channelCount: 2
            )
        }
        return AlbumID3(
            id: id, name: name, songCount: songs.count, duration: tracks.reduce(0) { $0 + $1.seconds },
            artist: artist.name, artistId: artist.id, coverArt: coverArt, year: year, genre: genre,
            releaseTypes: releaseTypes, releaseDate: releaseDate,
            recordLabels: label.map { [RecordLabel(name: $0)] }, song: songs
        )
    }

    private static func playlist(id: String, name: String, hoursAgo: Double, songs: [Song]) -> PlaylistWithSongs {
        PlaylistWithSongs(
            id: id, name: name, songCount: songs.count, duration: songs.reduce(0) { $0 + ($1.duration ?? 0) },
            owner: "listener", isPublic: false,
            changed: Date(timeIntervalSinceNow: -hoursAgo * 3_600), coverArt: "local:preview-\(id)", entry: songs
        )
    }

    /// SwiftSonic exposes no memberwise initialisers for these response types; they are Codable,
    /// so the previews build them the way the client does: from JSON.
    static func decode<T: Decodable>(_ type: T.Type, from object: some Encodable) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(object))
    }
}

// MARK: - Fake services

private nonisolated struct PreviewStarred: Encodable {
    let artist: [ArtistID3]
    let album: [AlbumID3]
    let song: [Song]
}

private nonisolated struct PreviewGenre: Encodable {
    let value: String
    let songCount: Int
    let albumCount: Int
}

private nonisolated struct PreviewArtistInfo: Encodable {
    let biography: String?
    let lastFmUrl: String?
}

/// Answers every library read the album, artist and home view models make, from `PreviewFixtures`.
nonisolated final class PreviewLibraryService: AlbumBrowsing, ArtistBrowsing, StarredBrowsing,
    ArtistRecommendationBrowsing, PlaylistBrowsing, RecentlyAddedAlbumBrowsing,
    ListeningHistoryBrowsing, GenreBrowsing, RecordLabelBrowsing {

    func albums(recordLabel: String) async throws -> [AlbumID3]? {
        PreviewFixtures.albums
            .filter { ($0.recordLabels ?? []).contains { $0.name == recordLabel } }
            .map(PreviewFixtures.withoutSongs)
    }

    func album(id: String) async throws -> AlbumID3 {
        guard let album = PreviewFixtures.album(id: id) else { throw URLError(.fileDoesNotExist) }
        return album
    }

    func allAlbums() async throws -> [AlbumID3] { PreviewFixtures.albums.map(PreviewFixtures.withoutSongs) }

    func artists() async throws -> [ArtistIndex] {
        let grouped = Dictionary(grouping: PreviewFixtures.artists) { String($0.name.prefix(1)).uppercased() }
        return grouped.keys.sorted().map { ArtistIndex(name: $0, artist: grouped[$0] ?? []) }
    }

    func artist(id: String) async throws -> ArtistID3 {
        guard let artist = PreviewFixtures.artistWithAlbums(id: id) else { throw URLError(.fileDoesNotExist) }
        return artist
    }

    func fetchAllTracks(forArtistID artistID: String) async throws -> [DisplayableSong] {
        PreviewFixtures.albums
            .filter { $0.artistId == artistID }
            .flatMap(PreviewFixtures.songs(of:))
            .map { DisplayableSong(from: $0) }
    }

    func appearances(artistID: String, artistName: String) async throws -> ArtistAppearanceResult {
        ArtistAppearances.result(
            from: PreviewFixtures.albums.flatMap(PreviewFixtures.songs(of:)),
            artistID: artistID,
            albumHeaders: Dictionary(uniqueKeysWithValues: PreviewFixtures.albums.map { ($0.id, PreviewFixtures.withoutSongs($0)) })
        )
    }

    func getStarred2() async throws -> Starred2 {
        try PreviewFixtures.decode(Starred2.self, from: PreviewStarred(
            artist: PreviewFixtures.starredArtists,
            album: PreviewFixtures.starredAlbums.map(PreviewFixtures.withoutSongs),
            song: PreviewFixtures.starredSongs
        ))
    }

    func getArtistInfo(forArtistID artistID: String, count: Int) async throws -> ArtistInfo {
        let isNora = artistID == PreviewFixtures.noraVale.id
        return try PreviewFixtures.decode(ArtistInfo.self, from: PreviewArtistInfo(
            biography: isNora ? PreviewFixtures.noraBiography : nil,
            lastFmUrl: isNora ? "https://www.last.fm/music/Nora+Vale" : nil
        ))
    }

    func getArtistMBID(forArtistID artistID: String) async throws -> String? { nil }

    func findArtist(byName name: String) async -> ArtistID3? {
        PreviewFixtures.artists.first { $0.name == name }
    }

    func topSongs(artist: String, count: Int) async throws -> [DisplayableSong] {
        let songs = PreviewFixtures.albums
            .filter { $0.artist == artist }
            .flatMap(PreviewFixtures.songs(of:))
        // A stable "most played" order: lead singles first, then everything else.
        let leads = songs.filter { [1, 2, 4].contains($0.track ?? 0) }
        return Array((leads + songs.filter { !leads.contains($0) }).prefix(count)).map { DisplayableSong(from: $0) }
    }

    func playlists() async throws -> [Playlist] {
        PreviewFixtures.playlists.map {
            Playlist(id: $0.id, name: $0.name, songCount: $0.songCount, duration: $0.duration,
                     owner: $0.owner, isPublic: $0.isPublic, changed: $0.changed, coverArt: $0.coverArt)
        }
    }

    func playlist(id: String) async throws -> PlaylistWithSongs {
        guard let playlist = PreviewFixtures.playlists.first(where: { $0.id == id }) else {
            throw URLError(.fileDoesNotExist)
        }
        return playlist
    }

    func recentlyAddedAlbums(size: Int) async throws -> [AlbumID3] {
        Array(PreviewFixtures.recentlyAdded.prefix(size)).map(PreviewFixtures.withoutSongs)
    }

    func recentlyPlayedAlbums(size: Int) async throws -> [AlbumID3] {
        Array(PreviewFixtures.recentlyPlayed.prefix(size)).map(PreviewFixtures.withoutSongs)
    }

    func mostPlayedAlbums(size: Int) async throws -> [AlbumID3] {
        Array(PreviewFixtures.mostPlayed.prefix(size)).map(PreviewFixtures.withoutSongs)
    }

    func genres() async throws -> [Genre] {
        let grouped = Dictionary(grouping: PreviewFixtures.albums) { $0.genre ?? "" }
        return try grouped.map { name, albums in
            try PreviewFixtures.decode(Genre.self, from: PreviewGenre(
                value: name, songCount: albums.reduce(0) { $0 + $1.songCount }, albumCount: albums.count
            ))
        }
    }

    func albumsByGenre(_ genre: String, size: Int) async throws -> [AlbumID3] {
        Array(PreviewFixtures.albums.filter { $0.genre == genre }.prefix(size)).map(PreviewFixtures.withoutSongs)
    }
}

/// Similar artists for the artist page. All are in the library, so the view model never asks
/// ExternalArtistImageResolver to look up portraits on the network.
actor PreviewRecommendationProvider: RecommendationProvider {
    func similarArtists(toArtistID: String, limit: Int) async throws -> [SimilarArtistRecommendation] {
        PreviewFixtures.artists
            .filter { $0.id != toArtistID }
            .prefix(limit)
            .map { SimilarArtistRecommendation(id: $0.id, name: $0.name, coverArt: $0.coverArt, inLibrary: true, mbid: nil) }
    }
}

// MARK: - Generated artwork

/// Renders a deterministic two-colour cover for each preview ID, so screens that theme
/// themselves from artwork (album page, full player) show realistic colours.
enum PreviewArtwork {
    private static let palettes: [String: (UInt32, UInt32)] = [
        "local:preview-al-tidal": (0x1D4E6B, 0x7FB7BE),
        "local:preview-al-lanterns": (0xC8553D, 0xF2D0A4),
        "local:preview-al-lowtide": (0x2E4057, 0x88A0A8),
        "local:preview-al-glasshouse": (0x6A8D73, 0xE4F0D0),
        "local:preview-al-static": (0x3A2E5C, 0x9C89B8),
        "local:preview-al-field": (0x5B4B2E, 0xC7A46C),
        "local:preview-al-transit": (0x7A1E48, 0xF08A5D),
        "local:preview-al-harbour": (0x0B1E3F, 0x1FC8DB),
        "local:preview-al-bluehour": (0x14213D, 0x4F6D9A),
        "local:preview-pl-commute": (0xF4A259, 0xF4E285),
        "local:preview-pl-jazz": (0x22223B, 0x9A8C98),
        "local:preview-pl-run": (0xD7263D, 0xF46036),
        "local:preview-pl-rainy": (0x3D5A80, 0x98C1D9),
        "local:preview-ar-nora": (0x274C5E, 0xA3C4BC),
        "local:preview-ar-kites": (0x4B3F72, 0xBFACE2),
        "local:preview-ar-moss": (0x4E6E3A, 0xC9D7A1),
        "local:preview-ar-hana": (0x8C2F39, 0xFCB9B2),
        "local:preview-ar-delta": (0x102542, 0x48E5C2),
        "local:preview-ar-ivo": (0x1B263B, 0x778DA9),
    ]

    static func pngData(for id: String) -> Data? {
        let (top, bottom) = palettes[id] ?? (0x444444, 0x999999)
        let size = CGSize(width: 600, height: 600)
        return UIGraphicsImageRenderer(size: size).pngData { context in
            let colors = [color(top).cgColor, color(bottom).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero,
                                                     end: CGPoint(x: size.width, y: size.height), options: [])
            }
            // A faint disc motif so covers read as artwork rather than flat swatches.
            UIColor.white.withAlphaComponent(0.14).setStroke()
            for inset in stride(from: 90.0, through: 250.0, by: 40.0) {
                let ring = UIBezierPath(ovalIn: CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset))
                ring.lineWidth = 6
                ring.stroke()
            }
        }
    }

    private static func color(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
    }
}

// MARK: - Preview container

extension AppContainer {
    /// An in-memory service graph with a configured (but never contacted) server, generated
    /// artwork, and a player paused or playing partway through Tidal Rooms.
    static func preview(isPlaying: Bool = true) -> AppContainer {
        let container: AppContainer
        do {
            container = try AppContainer(
                inMemory: true,
                userDefaults: UserDefaults(suiteName: "minidisc.previews") ?? .standard
            )
        } catch {
            fatalError("Preview AppContainer failed to initialise: \(error)")
        }

        let server = ServerConfig(displayName: "Home Navidrome", baseURL: "https://music.example.com",
                                  username: "listener", isActive: true, serverVersion: "0.53.3")
        container.modelContainer.mainContext.insert(server)
        let snapshot = ServerSnapshot(from: server)
        container.serverState.servers = [snapshot]
        container.serverState.activeServer = snapshot
        container.serverState.isConnected = true
        container.serverState.isLoadingPersistedState = false

        container.artworkImageCache.localArtworkProvider = { id in
            await PreviewArtwork.pngData(for: id)
        }

        let state = container.playerState
        let queue = PreviewFixtures.queue
        state.queue = queue
        state.currentIndex = 2
        state.currentTrack = queue[2]
        state.duration = queue[2].duration
        state.position = 74
        state.playbackState = isPlaying ? .playing : .paused
        state.applySourceKind(.stream(transcodedFormat: nil, maxBitRate: nil), revision: 1)
        return container
    }
}

// MARK: - View model factories

extension AlbumDetailViewModel {
    static func preview(albumId: String, container: AppContainer) -> AlbumDetailViewModel {
        let viewModel = AlbumDetailViewModel(
            albumId: albumId,
            libraryService: PreviewLibraryService(),
            downloadService: container.downloadService,
            toastService: container.toastService,
            serverState: container.serverState
        )
        if let album = PreviewFixtures.album(id: albumId) {
            viewModel.applyPreview(album)
        }
        return viewModel
    }
}

extension ArtistDetailViewModel {
    static func preview(artist: ArtistID3, container: AppContainer) -> ArtistDetailViewModel {
        ArtistDetailViewModel(
            artistId: artist.id,
            artistName: artist.name,
            libraryService: PreviewLibraryService(),
            downloadService: container.downloadService,
            recommendationService: RecommendationService(providers: [PreviewRecommendationProvider()]),
            imageResolver: container.externalArtistImageResolver,
            serverState: container.serverState
        )
    }
}

extension HomeFeedViewModel {
    /// No HomeFeedCache, so previews never read or write the app's saved Home feed.
    static func preview() -> HomeFeedViewModel {
        HomeFeedViewModel(libraryService: PreviewLibraryService())
    }
}

// MARK: - Environment

/// Supplies the same environment `MinidiscApp` and `MainTabView` give real screens.
struct MinidiscPreview<Content: View>: View {
    let container: AppContainer
    @ViewBuilder var content: Content
    @State private var playlistAddition = PlaylistAddition()

    var body: some View {
        content
            .environment(\.appContainer, container)
            .environment(container.dominantColorExtractor)
            .environment(container.artworkImageCache)
            .environment(container.toastService)
            .environment(playlistAddition)
            .modelContainer(container.modelContainer)
    }
}
#endif
