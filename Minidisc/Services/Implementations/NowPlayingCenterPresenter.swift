import Foundation
import MediaPlayer
import OSLog

import UIKit

/// Main-actor boundary for the Objective-C MediaPlayer surface.
///
/// Neither `[String: Any]` nor `MPMediaItemArtwork` leaves this type. The
/// coordinating `NowPlayingService` only exchanges `Sendable` snapshots and
/// artwork bytes across isolation domains.
@MainActor
final class NowPlayingCenterPresenter {
    private struct RegisteredTarget {
        let command: MPRemoteCommand
        let token: Any
    }

    private var registeredTargets: [RegisteredTarget] = []
    private var contentGeneration: UInt64 = 0

    func start(
        playerService: any PlayerServiceProtocol,
        likeAction: @escaping @Sendable () async -> Void
    ) {
        guard registeredTargets.isEmpty else { return }

        let center = MPRemoteCommandCenter.shared()

        register(center.playCommand) { [weak playerService] _ in
            Task(priority: .userInitiated) {
                await playerService?.resume()
            }
            return .success
        }

        register(center.pauseCommand) { [weak playerService] _ in
            Task(priority: .userInitiated) {
                await playerService?.pause()
            }
            return .success
        }

        register(center.togglePlayPauseCommand) { [weak playerService] _ in
            Task(priority: .userInitiated) {
                await playerService?.togglePlayPause()
            }
            return .success
        }

        register(center.nextTrackCommand) { [weak playerService] _ in
            Task(priority: .userInitiated) {
                do {
                    try await playerService?.skipToNext()
                } catch {
                    Logger.nowPlaying.error("[PLAYBACK] skipToNext failed: \(error, privacy: .public)")
                }
            }
            return .success
        }

        register(center.previousTrackCommand) { [weak playerService] _ in
            Task(priority: .userInitiated) {
                do {
                    try await playerService?.skipToPrevious()
                } catch {
                    Logger.nowPlaying.error("[PLAYBACK] skipToPrevious failed: \(error, privacy: .public)")
                }
            }
            return .success
        }

        center.likeCommand.localizedTitle = String(localized: "Add to Favorites")
        register(center.likeCommand) { _ in
            Task(priority: .userInitiated) {
                await likeAction()
            }
            return .success
        }

        register(center.changePlaybackPositionCommand) { [weak playerService] event in
            guard let seekEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let position = seekEvent.positionTime
            Task(priority: .userInitiated) {
                await playerService?.seek(to: position)
            }
            return .success
        }
    }

    func shutdown() {
        for target in registeredTargets {
            target.command.removeTarget(target.token)
        }
        registeredTargets.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func clear(generation: UInt64) {
        guard generation >= contentGeneration else { return }
        contentGeneration = generation
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func setBaseInfo(for snapshot: NowPlayingSnapshot, generation: UInt64) {
        guard generation >= contentGeneration else { return }
        contentGeneration = generation
        MPNowPlayingInfoCenter.default().nowPlayingInfo = makeBaseInfo(for: snapshot)
    }

    func mergePosition(
        elapsed: TimeInterval,
        rate: Float,
        duration: TimeInterval,
        generation: UInt64
    ) {
        guard generation == contentGeneration else { return }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        info[MPMediaItemPropertyPlaybackDuration] = duration
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func mergeSnapshot(_ snapshot: NowPlayingSnapshot, generation: UInt64) {
        guard generation == contentGeneration else { return }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyTitle] = snapshot.title
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = snapshot.position
        info[MPMediaItemPropertyPlaybackDuration] = snapshot.duration
        info[MPNowPlayingInfoPropertyPlaybackRate] = snapshot.playbackRate
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        if let artist = snapshot.artist {
            info[MPMediaItemPropertyArtist] = artist
        }
        if let album = snapshot.album {
            info[MPMediaItemPropertyAlbumTitle] = album
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func setArtwork(
        image: PlatformImage,
        fallback snapshot: NowPlayingSnapshot,
        generation: UInt64
    ) {
        guard generation == contentGeneration else { return }
        let artwork = Self.makeArtwork(image: image)
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? makeBaseInfo(for: snapshot)
        info[MPMediaItemPropertyArtwork] = artwork
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func setArtwork(data: Data, fallback snapshot: NowPlayingSnapshot, generation: UInt64) {
        guard generation == contentGeneration else { return }
        guard let image = PlatformImage(data: data) else {
            Logger.artworkCache.warning("NowPlayingCenterPresenter: downloaded artwork could not be decoded")
            return
        }
        setArtwork(image: image, fallback: snapshot, generation: generation)
    }

    func updateLikeCommand(songAvailable: Bool, isFavorite: Bool) {
        let command = MPRemoteCommandCenter.shared().likeCommand
        command.isEnabled = songAvailable
        command.isActive = isFavorite
    }

    func updateCommandAvailability(isLiveStream: Bool) {
        let center = MPRemoteCommandCenter.shared()
        center.nextTrackCommand.isEnabled = !isLiveStream
        center.previousTrackCommand.isEnabled = !isLiveStream
        center.changePlaybackPositionCommand.isEnabled = !isLiveStream
    }

    private func register(
        _ command: MPRemoteCommand,
        handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus
    ) {
        let token = command.addTarget(handler: handler)
        registeredTargets.append(RegisteredTarget(command: command, token: token))
    }

    private func makeBaseInfo(for snapshot: NowPlayingSnapshot) -> [String: Any] {
        if snapshot.isLiveStream {
            var info: [String: Any] = [
                MPMediaItemPropertyTitle: snapshot.title,
                MPNowPlayingInfoPropertyIsLiveStream: true,
                MPNowPlayingInfoPropertyPlaybackRate: snapshot.playbackRate,
                MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            ]
            if let artist = snapshot.artist {
                info[MPMediaItemPropertyArtist] = artist
            }
            return info
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: snapshot.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: snapshot.position,
            MPMediaItemPropertyPlaybackDuration: snapshot.duration,
            MPNowPlayingInfoPropertyPlaybackRate: snapshot.playbackRate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
        if let artist = snapshot.artist {
            info[MPMediaItemPropertyArtist] = artist
        }
        if let album = snapshot.album {
            info[MPMediaItemPropertyAlbumTitle] = album
        }
        return info
    }

    /// MediaPlayer invokes this request handler on its own callout queue. Keep the factory
    /// explicitly nonisolated: a closure created in this `@MainActor` type would otherwise inherit
    /// MainActor and trap in `_dispatch_assert_queue_fail` as soon as Now Playing serializes artwork.
    nonisolated static func makeArtwork(image: PlatformImage) -> MPMediaItemArtwork {
        let snapshot = SendableArtworkImage(image)
        return MPMediaItemArtwork(boundsSize: CGSize(width: 600, height: 600)) { _ in
            snapshot.image
        }
    }
}

/// `UIImage` is immutable for the lifetime of a Now Playing artwork request. MediaPlayer's API is
/// specifically designed to retain the image provider and call it from an internal serial queue,
/// but UIKit does not declare `UIImage` as Sendable. This wrapper documents and narrowly contains
/// that framework boundary without making the presenter or arbitrary UIKit values unchecked.
private nonisolated struct SendableArtworkImage: @unchecked Sendable {
    let image: PlatformImage

    init(_ image: PlatformImage) {
        self.image = image
    }
}
