import Foundation
import SwiftSonic
import OSLog

@Observable
@MainActor
final class ArtistDetailViewModel {
    var artist: ArtistID3?
    /// The artist's own releases grouped by category, in shelf order. Empty categories are omitted.
    private(set) var releaseShelves: [ArtistReleaseShelf] = []
    /// Albums not filed under this artist that credit them on a track. Online only.
    private(set) var appearsOn: [AlbumID3] = []
    /// Albums the server listed for the artist but files under someone else.
    private var listedCredits: [AlbumID3] = []
    /// Set when the server returned the artist without albums; resolved by `loadAppearances()`.
    private var deferredLocalFallback = false
    /// The credited tracks on `appearsOn`, newest album first. What Play uses for credit-only artists.
    private(set) var appearanceSongs: [DisplayableSong] = []
    /// True until the first appearance lookup finishes, so a credit-only artist is not shown as empty.
    private(set) var isLoadingAppearances = true

    /// The artist has nothing filed under them, only credits on other albums (e.g. an ensemble filed under
    /// its leader).
    var isCreditOnly: Bool { (artist?.album ?? []).isEmpty && !appearsOn.isEmpty }
    var isLoading = false
    var isPlayLoading = false
    var error: UserFacingError?
    var similarArtists: [SimilarArtistRecommendation] = []
    var isLoadingSimilarArtists = false
    var outOfLibraryArtistImages: [String: URL?] = [:]
    /// Most-played songs (getTopSongs). Empty on bare self-hosted servers → the view hides the section.
    var topSongs: [DisplayableSong] = []
    var isLoadingTopSongs = true

    var likedSongs: [DisplayableSong] = []
    var isLoadingLikedSongs = true

    var biography: String?
    var lastFmURL: URL?
    var isLoadingArtistInfo = true

    /// True when the screen is showing the downloaded copy rather than the server's catalogue.
    /// The view uses it to drop the sections that only exist online (bio, top songs, similar artists).
    var isOffline = false
    /// The artist's downloaded tracks in album order — what Play falls back to offline, since
    /// `fetchAllTracks(forArtistID:)` needs the network.
    var offlineTracks: [DisplayableSong] = []

    private let artistName: String?
    private let artistId: String
    private let libraryService: any ArtistBrowsing & StarredBrowsing & ArtistRecommendationBrowsing
    private let downloadService: any DownloadServiceProtocol
    private let recommendationService: RecommendationService
    private let imageResolver: ExternalArtistImageResolver
    private let serverState: ServerState
    private let offlineReader: OfflineBrowsingReader?

    init(
        artistId: String,
        artistName: String? = nil,
        libraryService: any ArtistBrowsing & StarredBrowsing & ArtistRecommendationBrowsing,
        downloadService: any DownloadServiceProtocol,
        recommendationService: RecommendationService,
        imageResolver: ExternalArtistImageResolver,
        serverState: ServerState,
        offlineReader: OfflineBrowsingReader? = nil
    ) {
        self.artistId = artistId
        self.artistName = artistName
        self.libraryService = libraryService
        self.downloadService = downloadService
        self.recommendationService = recommendationService
        self.imageResolver = imageResolver
        self.serverState = serverState
        self.offlineReader = offlineReader
    }

    func load() async {
        isLoading = true
        error = nil
        if serverState.isOnline {
            await loadFromAPI()
        } else {
            isOffline = true
            await loadFromLocal()
        }
        isLoading = false
    }

    private func loadFromAPI() async {
        do {
            let fetched = try await libraryService.artist(id: artistId)
            // A record with no albums is normal for credit-only artists (an ensemble filed under its leader),
            // but it is also what a captive proxy's empty 200 looks like. Stay online and decide once Appears
            // On has loaded: only when that is empty too does the downloaded copy replace the page.
            deferredLocalFallback = (fetched.album ?? []).isEmpty
            setArtist(fetched)
            isOffline = false
        } catch {
            if await loadFromLocal() { return }
            self.error = UserFacingError.from(error)
        }
    }

    /// Rebuilds the artist from downloads. Returns true only when something was on disk, and sets
    /// `isOffline` only then — a transient online failure must not blank a page that already loaded.
    @discardableResult
    private func loadFromLocal() async -> Bool {
        guard let serverId = serverState.activeServer?.id else { return false }
        let data: LocalArtistData?
        if let offlineReader, let snapshot = try? await offlineReader.read(serverID: serverId) {
            let tracks = snapshot.artistSongs(artistId)
            let albums = snapshot.albums.filter { $0.artistId == artistId }.map {
                LocalAlbumData(albumId: $0.id, albumName: $0.name, artistName: $0.artist,
                               coverArtId: $0.coverArt, songs: snapshot.albumSongs($0.id))
            }
            data = tracks.isEmpty ? nil : LocalArtistData(artistId: artistId, artistName: artistName ?? tracks[0].artist ?? artistId,
                coverArtId: tracks[0].coverArtId, albums: albums, tracks: tracks)
        } else {
            data = await downloadService.localArtistData(artistId: artistId, artistName: artistName ?? artist?.name, serverId: serverId)
        }
        guard !Task.isCancelled, serverState.activeServer?.id == serverId, let data, !data.tracks.isEmpty else { return false }

        setArtist(ArtistID3(
            id: data.artistId,
            name: data.artistName,
            albumCount: data.albums.count,
            coverArt: data.coverArtId,
            album: data.albums.map { album in
                // No year offline — DownloadedAlbum/DownloadedTrack never persist it.
                AlbumID3(
                    id: album.albumId,
                    name: album.albumName,
                    songCount: album.songs.count,
                    duration: Int(album.songs.reduce(0) { $0 + $1.duration }),
                    artist: album.artistName,
                    artistId: data.artistId,
                    coverArt: album.coverArtId
                )
            }
        ))
        offlineTracks = data.tracks
        // The online-only sections have nothing to fetch: clear their loading flags so the view
        // collapses them instead of showing skeletons that never resolve.
        topSongs = []
        likedSongs = []
        similarArtists = []
        biography = nil
        lastFmURL = nil
        isLoadingTopSongs = false
        isLoadingLikedSongs = false
        isLoadingSimilarArtists = false
        isLoadingArtistInfo = false
        isLoadingAppearances = false
        isOffline = true
        return true
    }

    private func setArtist(_ loadedArtist: ArtistID3) {
        let listed = loadedArtist.album ?? []
        // Servers (and cached artist records) can list albums the artist is only credited on; those
        // belong in Appears On, so the discography only holds albums filed under the artist.
        let releases = listed.filter { ArtistAppearances.isFiled($0, under: artistId, named: loadedArtist.name) }
        listedCredits = listed.filter { !ArtistAppearances.isFiled($0, under: artistId, named: loadedArtist.name) }
        artist = ArtistID3(
            id: loadedArtist.id,
            name: loadedArtist.name,
            albumCount: releases.count,
            coverArt: loadedArtist.coverArt,
            starred: loadedArtist.starred,
            userRating: loadedArtist.userRating,
            musicBrainzId: loadedArtist.musicBrainzId,
            sortName: loadedArtist.sortName,
            roles: loadedArtist.roles,
            album: releases
        )
        let grouped = Dictionary(grouping: releases, by: \.minidiscReleaseCategory)
        releaseShelves = AlbumReleaseCategory.allCases.compactMap { category in
            guard let albums = grouped[category], !albums.isEmpty else { return nil }
            return ArtistReleaseShelf(category: category, albums: albums)
        }
    }

    /// Call after `load()`, which resolves the artist name and its own discography.
    func loadAppearances() async {
        guard !isOffline, let name = artist?.name ?? artistName else {
            appearsOn = []
            appearanceSongs = []
            isLoadingAppearances = false
            return
        }
        let ownAlbumIDs = Set((artist?.album ?? []).map(\.id))
        do {
            let result = try await libraryService.appearances(artistID: artistId, artistName: name)
            // Prefer the server's own header for albums it listed on the artist record (real song counts).
            let listedByID = Dictionary(listedCredits.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var merged = result.albums.map { listedByID[$0.id] ?? $0 }
            let found = Set(merged.map(\.id))
            merged += listedCredits.filter { !found.contains($0.id) }
            appearsOn = merged
                .filter { !ownAlbumIDs.contains($0.id) }
                .sorted { ($0.year ?? 0) > ($1.year ?? 0) }
            let visibleIDs = Set(appearsOn.map(\.id))
            appearanceSongs = result.songs
                .filter { $0.albumId.map(visibleIDs.contains) ?? false }
                .map { DisplayableSong(from: $0) }
        } catch is CancellationError {
            return
        } catch {
            Logger.library.warning("appearances failed for \(self.artistId, privacy: .public): \(error, privacy: .public)")
            appearsOn = []
            appearanceSongs = []
        }
        if deferredLocalFallback {
            deferredLocalFallback = false
            // No filed albums and no credits: the empty record was not a credit-only artist, so prefer
            // whatever is downloaded over an empty screen.
            if appearsOn.isEmpty, (artist?.album ?? []).isEmpty {
                await loadFromLocal()
            }
        }
        isLoadingAppearances = false
    }

    /// Top songs (getTopSongs takes the artist NAME) — call after `load()` so `artist?.name` is set.
    func loadTopSongs() async {
        guard !isOffline else { isLoadingTopSongs = false; return }
        guard let name = artist?.name else { isLoadingTopSongs = false; return }
        isLoadingTopSongs = true
        defer { isLoadingTopSongs = false }
        do {
            topSongs = try await libraryService.topSongs(artist: name, count: 25)
        } catch {
            Logger.recommendations.warning("topSongs failed for \(self.artistId): \(error)")
            topSongs = []
        }
    }

    /// Filters getStarred2 after load resolves the artist name needed for ID-less responses.
    func loadLikedSongs() async {
        guard !isOffline else { isLoadingLikedSongs = false; return }
        isLoadingLikedSongs = true
        defer { isLoadingLikedSongs = false }
        do {
            let starred = try await libraryService.getStarred2()
            likedSongs = ArtistBestOf.songs(of: artistId, named: artist?.name, in: starred.song ?? [])
        } catch {
            Logger.favorites.warning("liked songs failed for \(self.artistId): \(error)")
            likedSongs = []
        }
    }

    /// Loads artist information independently of recommendations under the service timeout.
    func loadArtistInfo() async {
        guard !isOffline else { isLoadingArtistInfo = false; return }
        defer { isLoadingArtistInfo = false }
        do {
            let info = try await libraryService.getArtistInfo(forArtistID: artistId, count: 20)
            let cleaned = info.biography?.strippingArtistBioMarkup
            biography = (cleaned?.isEmpty ?? true) ? nil : cleaned
            lastFmURL = info.lastFmUrl.flatMap(URL.init(string:))
        } catch {
            Logger.recommendations.warning("artistInfo failed for \(self.artistId): \(error)")
        }
    }

    // Called from the view's .task after load() returns so artist loading and
    // index/network calls from similar artists never compete on the same server.
    func loadSimilarArtists() async {
        guard !isOffline else { isLoadingSimilarArtists = false; return }
        isLoadingSimilarArtists = true
        similarArtists = []
        defer { isLoadingSimilarArtists = false }
        do {
            similarArtists = try await recommendationService.similarArtists(to: artistId)
        } catch {
            Logger.recommendations.warning("similarArtists failed for \(self.artistId): \(error)")
        }
        Task { await loadOutOfLibraryImages() }
    }

    private func loadOutOfLibraryImages() async {
        for rec in similarArtists where !rec.inLibrary {
            let url = await imageResolver.resolveImageURL(for: rec)
            outOfLibraryArtistImages[rec.id] = url
        }
    }
}

private extension String {
    /// Turns a Last.fm/MusicBrainz biography into plain text: drops HTML tags and the
    /// trailing "Read more on Last.fm" link that Subsonic servers pass through verbatim.
    var strippingArtistBioMarkup: String {
        var text = self

        if let range = text.range(of: "<a", options: .backwards),
           text[range.lowerBound...].localizedCaseInsensitiveContains("last.fm") {
            text = String(text[..<range.lowerBound])
        }

        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, char) in ["&amp;": "&", "&quot;": "\"", "&#39;": "'", "&lt;": "<", "&gt;": ">", "&apos;": "'"] {
            text = text.replacingOccurrences(of: entity, with: char)
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

nonisolated struct ArtistReleaseShelf: Identifiable, Sendable {
    let category: AlbumReleaseCategory
    let albums: [AlbumID3]

    var id: AlbumReleaseCategory { category }
}
