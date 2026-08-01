import Foundation
import OSLog

actor NowPlayingService: NowPlayingServiceProtocol {
    private weak var playerService: (any PlayerServiceProtocol)?
    private let artworkLoader = ArtworkLoader()
    private let artworkImageCache: ArtworkImageCache
    private let presenter: NowPlayingCenterPresenter
    private var commandsRegistered = false
    private var currentSong: NowPlayingSnapshot?
    private var contentGeneration: UInt64 = 0
    private var favoritesService: (any FavoritesServiceProtocol)?

    init(
        playerService: any PlayerServiceProtocol,
        artworkImageCache: ArtworkImageCache,
        presenter: NowPlayingCenterPresenter
    ) {
        self.playerService = playerService
        self.artworkImageCache = artworkImageCache
        self.presenter = presenter
    }

    func setFavoritesService(_ service: any FavoritesServiceProtocol) {
        favoritesService = service
    }

    // MARK: - Lifecycle

    func start() async {
        guard !commandsRegistered, let playerService else { return }
        commandsRegistered = true

        await presenter.start(playerService: playerService) { [weak self] in
            await self?.toggleFavoriteForCurrentTrack()
        }
    }

    func stop() async {
        contentGeneration &+= 1
        let generation = contentGeneration
        currentSong = nil
        await presenter.clear(generation: generation)
        guard generation == contentGeneration else { return }
        await refreshLikeCommandState()
    }

    // MARK: - Update

    func update(with snapshot: NowPlayingSnapshot) async {
        if snapshot.isLiveStream {
            contentGeneration &+= 1
            let generation = contentGeneration
            currentSong = nil
            // Omitting duration and elapsed time hides the live-stream scrubber.
            await presenter.setBaseInfo(for: snapshot, generation: generation)
            guard generation == contentGeneration else { return }
            await refreshLikeCommandState()

            if let coverArtId = snapshot.coverArtId,
               let cachedImage = await artworkImageCache.cached(for: coverArtId, tier: .hero) {
                guard generation == contentGeneration else { return }
                await presenter.setArtwork(
                    image: cachedImage,
                    fallback: snapshot,
                    generation: generation
                )
            }

            guard generation == contentGeneration else { return }
            await updateRemoteCommandsAvailability(isLiveStream: true)
            return
        }

        if let songId = snapshot.songId, currentSong?.songId == songId {
            let generation = contentGeneration
            await updateRemoteCommandsAvailability(isLiveStream: false)
            guard generation == contentGeneration, currentSong?.songId == songId else { return }
            // Merge position updates so already-loaded artwork survives.
            await presenter.mergeSnapshot(snapshot, generation: generation)
            return
        }

        contentGeneration &+= 1
        let generation = contentGeneration

        // Commit text first and clear stale artwork while the new image loads.
        currentSong = snapshot
        await presenter.setBaseInfo(for: snapshot, generation: generation)
        guard generation == contentGeneration, currentSong?.songId == snapshot.songId else { return }
        await updateRemoteCommandsAvailability(isLiveStream: false)
        guard generation == contentGeneration, currentSong?.songId == snapshot.songId else { return }
        await refreshLikeCommandState()
        guard generation == contentGeneration, currentSong?.songId == snapshot.songId else { return }

        if let coverArtId = snapshot.coverArtId,
           let cachedImage = await artworkImageCache.cached(for: coverArtId, tier: .hero) {
            guard generation == contentGeneration, currentSong?.songId == snapshot.songId else { return }
            await presenter.setArtwork(
                image: cachedImage,
                fallback: snapshot,
                generation: generation
            )
            return
        }

        if let artworkURL = snapshot.artworkURL,
           let data = await artworkLoader.data(for: artworkURL, headers: snapshot.artworkHeaders) {
            guard generation == contentGeneration, currentSong?.songId == snapshot.songId else { return }
            await presenter.setArtwork(data: data, fallback: snapshot, generation: generation)
        }
    }

    // MARK: - Periodic position push

    func pushPosition(
        elapsed: TimeInterval,
        rate: Float,
        duration: TimeInterval,
        songId: String
    ) async {
        guard elapsed >= 0, duration > 0, currentSong?.songId == songId else { return }
        let generation = contentGeneration
        await presenter.mergePosition(
            elapsed: elapsed,
            rate: rate,
            duration: duration,
            generation: generation
        )
    }

    // MARK: - Favourite

    private func toggleFavoriteForCurrentTrack() async {
        guard let favoritesService, let songId = currentSong?.songId else { return }
        let generation = contentGeneration
        let wasFavorite = await favoritesService.isFavorite(itemType: .song, itemId: songId)
        guard generation == contentGeneration, currentSong?.songId == songId else { return }
        do {
            if wasFavorite {
                try await favoritesService.unstar(itemType: .song, itemId: songId)
            } else {
                try await favoritesService.star(itemType: .song, itemId: songId)
            }
            await refreshLikeCommandState()
            Logger.nowPlaying.info("[REMOTE] \(wasFavorite ? "unstarred" : "starred", privacy: .public) '\(songId, privacy: .public)' from a remote surface")
        } catch {
            Logger.nowPlaying.warning("[REMOTE] favourite toggle failed for '\(songId, privacy: .public)': \(error, privacy: .public)")
        }
    }

    private func refreshLikeCommandState() async {
        let generation = contentGeneration
        let songId = currentSong?.songId
        let isFavorite: Bool
        if let songId, let favoritesService {
            isFavorite = await favoritesService.isFavorite(itemType: .song, itemId: songId)
        } else {
            isFavorite = false
        }
        guard generation == contentGeneration, songId == currentSong?.songId else { return }
        await presenter.updateLikeCommand(songAvailable: songId != nil, isFavorite: isFavorite)
    }

    // MARK: - Remote command availability

    private func updateRemoteCommandsAvailability(isLiveStream: Bool) async {
        await presenter.updateCommandAvailability(isLiveStream: isLiveStream)
        Logger.nowPlaying.debug(
            "[REMOTE] command availability updated — live=\(isLiveStream, privacy: .public) seek/next/previous=\(!isLiveStream, privacy: .public)"
        )
    }

}
