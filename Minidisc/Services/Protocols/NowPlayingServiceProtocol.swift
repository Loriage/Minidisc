import Foundation

/// Owns system Now Playing metadata and remote commands.
protocol NowPlayingServiceProtocol: AnyObject, Sendable {
    func start() async

    /// Clears the current metadata when playback stops. Remote command handlers
    /// remain registered for the lifetime of the app service graph, so a later
    /// playback session remains controllable without re-registering targets.
    func stop() async

    /// Late-wired dependency for the remote like command — FavoritesService is built after this
    /// service in AppContainer.
    func setFavoritesService(_ service: any FavoritesServiceProtocol) async

    func update(with snapshot: NowPlayingSnapshot) async

    /// Merges elapsed time, rate, and duration into the existing nowPlayingInfo dict without
    /// touching title, artist, or artwork. Called on every periodic tick to prevent iOS
    /// extrapolation drift on the lock screen.
    func pushPosition(
        elapsed: TimeInterval,
        rate: Float,
        duration: TimeInterval,
        songId: String
    ) async
}
