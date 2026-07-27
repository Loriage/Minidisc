import Foundation
import MediaPlayer
import OSLog

actor NowPlayingService: NowPlayingServiceProtocol {
    private let playerService: any PlayerServiceProtocol
    private let artworkLoader = ArtworkLoader()
    private let artworkImageCache: ArtworkImageCache
    private var commandsRegistered = false
    private var currentSong: NowPlayingSnapshot?
    private var contentGeneration: UInt64 = 0
    private var favoritesService: (any FavoritesServiceProtocol)?

    init(playerService: any PlayerServiceProtocol, artworkImageCache: ArtworkImageCache) {
        self.playerService = playerService
        self.artworkImageCache = artworkImageCache
    }

    func setFavoritesService(_ service: any FavoritesServiceProtocol) {
        favoritesService = service
    }

    // MARK: - Lifecycle

    func start() async {
        guard !commandsRegistered else { return }
        commandsRegistered = true

        let playerService = playerService

        // Register atomically on the main actor before iOS snapshots supported commands.
        await MainActor.run {
            let center = MPRemoteCommandCenter.shared()

            center.playCommand.addTarget { [playerService] _ in
                Task.detached(priority: .userInitiated) {
                    await playerService.resume()
                }
                return .success
            }

            center.pauseCommand.addTarget { [playerService] _ in
                Task.detached(priority: .userInitiated) {
                    await playerService.pause()
                }
                return .success
            }

            center.togglePlayPauseCommand.addTarget { [playerService] _ in
                Task.detached(priority: .userInitiated) {
                    await playerService.togglePlayPause()
                }
                return .success
            }

            center.nextTrackCommand.addTarget { [playerService] _ in
                Task.detached(priority: .userInitiated) {
                    do {
                        try await playerService.skipToNext()
                    } catch {
                        Logger.nowPlaying.error("[PLAYBACK] skipToNext failed: \(error, privacy: .public)")
                    }
                }
                return .success
            }

            center.previousTrackCommand.addTarget { [playerService] _ in
                Task.detached(priority: .userInitiated) {
                    do {
                        try await playerService.skipToPrevious()
                    } catch {
                        Logger.nowPlaying.error("[PLAYBACK] skipToPrevious failed: \(error, privacy: .public)")
                    }
                }
                return .success
            }

            center.likeCommand.localizedTitle = String(localized: "Add to Favorites")
            center.likeCommand.addTarget { [weak self] _ in
                Task { await self?.toggleFavoriteForCurrentTrack() }
                return .success
            }

            center.changePlaybackPositionCommand.addTarget { [playerService] event in
                guard let seekEvent = event as? MPChangePlaybackPositionCommandEvent else {
                    return .commandFailed
                }
                let position = seekEvent.positionTime
                Task.detached(priority: .userInitiated) {
                    await playerService.seek(to: position)
                }
                return .success
            }
        }
    }

    func stop() async {
        contentGeneration &+= 1
        currentSong = nil
        await refreshLikeCommandState()
        await MainActor.run {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
    }

    // MARK: - Update

    func update(with snapshot: NowPlayingSnapshot) async {
        if snapshot.isLiveStream {
            contentGeneration &+= 1
            let generation = contentGeneration
            currentSong = nil
            await refreshLikeCommandState()
            // Omitting duration and elapsed time hides the live-stream scrubber.
            var info: [String: Any] = [
                MPMediaItemPropertyTitle: snapshot.title,
                MPNowPlayingInfoPropertyIsLiveStream: true,
                MPNowPlayingInfoPropertyPlaybackRate: snapshot.playbackRate,
                MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0
            ]
            if let artist = snapshot.artist { info[MPMediaItemPropertyArtist] = artist }
            let baseInfo = info
            await MainActor.run {
                MPNowPlayingInfoCenter.default().nowPlayingInfo = baseInfo
            }

            if let coverArtId = snapshot.coverArtId,
               let cachedImage = await artworkImageCache.cached(for: coverArtId, tier: .hero) {
                guard generation == contentGeneration else { return }
                let artwork = MPMediaItemArtwork(boundsSize: CGSize(width: 600, height: 600)) { _ in cachedImage }
                await MainActor.run {
                    var infoWithArt = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? baseInfo
                    infoWithArt[MPMediaItemPropertyArtwork] = artwork
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = infoWithArt
                }
            }

            await updateRemoteCommandsAvailability(isLiveStream: true)
            return
        }

        await updateRemoteCommandsAvailability(isLiveStream: false)

        if let songId = snapshot.songId, currentSong?.songId == songId {
            // Merge position updates so already-loaded artwork survives.
            await MainActor.run {
                var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                info[MPMediaItemPropertyTitle] = snapshot.title
                info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = snapshot.position
                info[MPMediaItemPropertyPlaybackDuration] = snapshot.duration
                info[MPNowPlayingInfoPropertyPlaybackRate] = snapshot.playbackRate
                info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
                if let artist = snapshot.artist { info[MPMediaItemPropertyArtist] = artist }
                if let album = snapshot.album { info[MPMediaItemPropertyAlbumTitle] = album }
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            }
            return
        }

        contentGeneration &+= 1
        let generation = contentGeneration

        // Commit text first and clear stale artwork while the new image loads.
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: snapshot.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: snapshot.position,
            MPMediaItemPropertyPlaybackDuration: snapshot.duration,
            MPNowPlayingInfoPropertyPlaybackRate: snapshot.playbackRate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0
        ]
        if let artist = snapshot.artist { info[MPMediaItemPropertyArtist] = artist }
        if let album = snapshot.album { info[MPMediaItemPropertyAlbumTitle] = album }
        currentSong = snapshot
        await refreshLikeCommandState()
        guard generation == contentGeneration, currentSong?.songId == snapshot.songId else { return }
        let baseInfo = info
        await MainActor.run {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = baseInfo
        }

        if let coverArtId = snapshot.coverArtId,
           let cachedImage = await artworkImageCache.cached(for: coverArtId, tier: .hero) {
            guard generation == contentGeneration, currentSong?.songId == snapshot.songId else { return }
            let artwork = MPMediaItemArtwork(boundsSize: CGSize(width: 600, height: 600)) { _ in cachedImage }
            let fallback = baseInfo
            await MainActor.run {
                var infoWithArt = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? fallback
                infoWithArt[MPMediaItemPropertyArtwork] = artwork
                MPNowPlayingInfoCenter.default().nowPlayingInfo = infoWithArt
            }
            return
        }

        if let artworkURL = snapshot.artworkURL,
           let artwork = await artworkLoader.artwork(for: artworkURL, headers: snapshot.artworkHeaders) {
            guard generation == contentGeneration, currentSong?.songId == snapshot.songId else { return }
            let fallback = baseInfo
            await MainActor.run {
                var infoWithArt = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? fallback
                infoWithArt[MPMediaItemPropertyArtwork] = artwork
                MPNowPlayingInfoCenter.default().nowPlayingInfo = infoWithArt
            }
        }
    }

    // MARK: - Periodic position push

    func pushPosition(elapsed: TimeInterval, rate: Float, duration: TimeInterval) async {
        guard elapsed >= 0, duration > 0 else { return }
        await MainActor.run {
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
            info[MPNowPlayingInfoPropertyPlaybackRate] = rate
            info[MPMediaItemPropertyPlaybackDuration] = duration
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }

    // MARK: - Favourite

    private func toggleFavoriteForCurrentTrack() async {
        guard let favoritesService, let songId = currentSong?.songId else { return }
        let wasFavorite = await MainActor.run { favoritesService.isFavorite(itemType: .song, itemId: songId) }
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
        let songId = currentSong?.songId
        let isFavorite: Bool
        if let songId, let favoritesService {
            isFavorite = await MainActor.run { favoritesService.isFavorite(itemType: .song, itemId: songId) }
        } else {
            isFavorite = false
        }
        await MainActor.run {
            let command = MPRemoteCommandCenter.shared().likeCommand
            command.isEnabled = songId != nil
            command.isActive = isFavorite
        }
    }

    // MARK: - Remote command availability

    private func updateRemoteCommandsAvailability(isLiveStream: Bool) async {
        await MainActor.run {
            let center = MPRemoteCommandCenter.shared()
            center.nextTrackCommand.isEnabled = !isLiveStream
            center.previousTrackCommand.isEnabled = !isLiveStream
            center.changePlaybackPositionCommand.isEnabled = !isLiveStream
        }
        Logger.nowPlaying.debug(
            "[REMOTE] command availability updated — live=\(isLiveStream, privacy: .public) seek/next/previous=\(!isLiveStream, privacy: .public)"
        )
    }

}
