import Foundation
import SwiftSonic

protocol PlayerServiceProtocol: AnyObject, Sendable {
    var state: PlayerState { get }

    func play(tracks: [DisplayableSong], startIndex: Int) async throws
    /// Resolves a fresh queue without allowing a late result to override Pause, Next or another Play.
    func play(preparingQueue: @escaping @Sendable () async throws -> PreparedPlaybackQueue) async throws
    func resume() async
    func pause() async
    func stop() async
    func skipToNext() async throws
    func skipToPrevious() async throws
    /// Selects an item in the current queue only if the caller's queue snapshot is still current.
    /// Returns false when the request became stale before it reached the player actor.
    func selectQueueTrack(_ selection: QueueTrackSelection) async throws -> Bool
    func seek(to position: TimeInterval) async
    func setRepeatMode(_ mode: RepeatMode) async
    func toggleShuffle() async
    func appendToQueue(_ tracks: [DisplayableSong]) async
    func playNext(_ song: DisplayableSong) async
    func playNext(_ songs: [DisplayableSong]) async
    func addToQueue(_ song: DisplayableSong) async
    func addToQueue(_ songs: [DisplayableSong]) async
    func removeFromQueue(at index: Int) async
    func removeQueueTrack(_ selection: QueueTrackSelection) async -> QueueRemoval?
    func restoreQueueTrack(_ removal: QueueRemoval) async -> Bool
    func moveQueueTrack(_ selection: QueueTrackSelection, toIndex: Int) async
    func moveInQueue(fromIndex: Int, toIndex: Int) async
    func restoreSession() async
    /// Invalidates network-bound playback resources after a meaningful path transition.
    /// Generation zero is the launch baseline and is intentionally ignored by recovery logic.
    func handleNetworkPathChanged(_ event: NetworkPathEvent) async
    /// Starts live stream playback of an Internet Radio Station.
    /// Clears the current queue's playing state but preserves the queue itself.
    func playRadio(_ station: InternetRadioStation) async throws
    /// Builds a Smart Shuffle queue via LibraryService and starts playback. Replaces the current queue.
    /// Throws `MinidiscError.smartShuffleEmpty` if no eligible tracks (library too small / no downloads offline).
    func playSmartShuffle() async throws
    /// A supplied seedTrack starts immediately while similarity queries build the queue.
    /// Without it, waits for the mix and throws instantMixEmpty if none is available.
    func playInstantMix(from seed: InstantMixSeed, startingWith seedTrack: DisplayableSong?) async throws
    func setAutoExtendEnabled(_ enabled: Bool) async
    func setVolume(_ volume: Float) async
    func togglePlayPause() async
    func saveCurrentPosition() async
    /// Re-reads ReplayGainSettings and reapplies gain to the current track.
    /// Call this whenever the user changes any ReplayGain setting.
    func replayGainSettingsDidChange() async
    /// Updates the stored CrossfadeConfig snapshot without rebuilding a transition already prepared.
    /// Call whenever the user changes any crossfade setting; the new value applies to the next preload.
    func crossfadeSettingsDidChange() async
    /// Stops the audio engine synchronously without going through the actor.
    /// Only safe to call during app termination (single-threaded, no concurrent access).
    nonisolated func stopAudioEngineSync()
}

nonisolated struct PreparedPlaybackQueue: Sendable {
    let tracks: [DisplayableSong]
    let startIndex: Int
    var repeatMode: RepeatMode? = nil
}

extension PlayerServiceProtocol {
    nonisolated func play(preparingQueue: @escaping @Sendable () async throws -> PreparedPlaybackQueue) async throws {
        let queue = try await preparingQueue()
        if let repeatMode = queue.repeatMode { await setRepeatMode(repeatMode) }
        try await play(tracks: queue.tracks, startIndex: queue.startIndex)
    }
}
