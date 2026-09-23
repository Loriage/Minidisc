import Foundation
import SwiftSonic
import OSLog

@Observable
@MainActor
final class ArtistDetailViewModel {
    var artist: ArtistID3?
    private(set) var albumReleases: [AlbumID3] = []
    private(set) var singlesAndEPs: [AlbumID3] = []
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
            // Empty-success guard: behind a captive proxy the server answers 200 with no albums.
            // That never throws, so prefer the downloaded copy over an empty screen.
            if (fetched.album ?? []).isEmpty, await loadFromLocal() { return }
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
        isOffline = true
        return true
    }

    private func setArtist(_ loadedArtist: ArtistID3) {
        artist = loadedArtist
        let releases = loadedArtist.album ?? []
        albumReleases = releases.filter { $0.minidiscReleaseCategory == .album }
        singlesAndEPs = releases.filter { $0.minidiscReleaseCategory == .singleOrEP }
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
