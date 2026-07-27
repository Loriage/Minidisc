// Minidisc — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import MediaPlayer
import OSLog

/// Manages MPNowPlayingInfoCenter + MPRemoteCommandCenter.
/// Active from v1 (lockscreen, Control Center, AirPods, Apple Watch).
/// Architected as the direct extension point for CarPlay (v1.2) — no refactor needed.
actor NowPlayingService: NowPlayingServiceProtocol {
    private let playerService: any PlayerServiceProtocol
    private let artworkLoader = ArtworkLoader()
    private let artworkImageCache: ArtworkImageCache
    private var commandsRegistered = false
    private var currentSong: NowPlayingSnapshot?
    /// Invalidates artwork/favourite work that suspended while a newer track became current.
    private var contentGeneration: UInt64 = 0
    /// Wired after init — FavoritesService is built later in AppContainer, same as the
    /// PlayerService→NowPlayingService link.
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

        // Register every command handler SYNCHRONOUSLY, on the MAIN THREAD, in ONE atomic block — before any
        // actor suspension and before the first now-playing info is set. MPRemoteCommandCenter is a main-thread
        // API: registering it from the NowPlayingService actor (off-main) let iOS snapshot setSupportedCommands
        // mid-registration — capturing only {Play, Pause} and never re-snapshotting, so Next / Previous /
        // scrubber showed greyed out (partial/random by run = the registration-vs-snapshot race). One
        // main-thread block guarantees the supported set is COMPLETE at iOS's single snapshot. addTarget is what
        // makes a command "supported"; isEnabled (in updateRemoteCommandsAvailability) only greys/ungreys it.
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

            // Favourite the playing track from a remote surface. Registered here with the rest so it
            // is inside iOS's single supported-commands snapshot (see the note above).
            //
            // NOTE ON WHERE THIS SHOWS UP: iOS's own Now Playing UI — Lock Screen, Dynamic Island,
            // Control Center — has no slot for a like button and will not render one, whatever we
            // register. This command reaches the surfaces that DO have one: CarPlay's Now Playing
            // and the Apple Watch remote. Registering it costs nothing and is what CarPlay will read
            // when that scene lands.
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
            // Live stream: fresh dict with the IsLiveStream flag set.
            // Duration and elapsed time are intentionally omitted — Control Center hides
            // the scrubber automatically when MPNowPlayingInfoPropertyIsLiveStream is true.
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

            // Check ArtworkImageCache — use hero tier for lock screen / Control Center quality.
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
            // Position-only update (pause/resume/seek): merge into the existing dict so
            // artwork already loaded for the current track is preserved.
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

        // New track: build from scratch so stale artwork from the previous track is cleared
        // before the new one loads. Text metadata is committed first so the lockscreen
        // doesn't flash empty while the artwork fetch is in progress.
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

        // Fast path: image already in ArtworkImageCache (pre-loaded when the card was visible).
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

        // Slow path: fetch from URL and populate both caches.
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

    /// Stars or unstars whatever is playing, driven from a remote surface (CarPlay, Watch).
    /// Radio is excluded — a live stream has no song to favourite.
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

    /// Mirrors the stored favourite state onto the command, so a remote surface that draws the
    /// button filled/unfilled draws it right. Disabled for radio, which cannot be favourited.
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
        // MPRemoteCommandCenter is a main-thread API. Keep availability changes on the same executor
        // as initial command registration so iOS never observes a half-updated command set.
        await MainActor.run {
            let center = MPRemoteCommandCenter.shared()
            center.nextTrackCommand.isEnabled = !isLiveStream
            center.previousTrackCommand.isEnabled = !isLiveStream
            center.changePlaybackPositionCommand.isEnabled = !isLiveStream
        }
        // Skip, previous, and scrubbing are meaningless for a live stream.
        // play/pause/togglePlayPause remain enabled in both modes (always-on).
        Logger.nowPlaying.debug(
            "[REMOTE] command availability updated — live=\(isLiveStream, privacy: .public) seek/next/previous=\(!isLiveStream, privacy: .public)"
        )
    }

}
