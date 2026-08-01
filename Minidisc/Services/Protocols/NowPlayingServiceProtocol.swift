import Foundation

/// Manages MPNowPlayingInfoCenter and MPRemoteCommandCenter.
/// Active from v1: lockscreen, Control Center, AirPods, Apple Watch.
/// Designed as the direct extension point for CarPlay in v1.2 — no refactor needed.
protocol NowPlayingServiceProtocol: AnyObject, Sendable {
    /// Registers remote command handlers and begins observing PlayerState.
    func start() async

    /// Clears the current metadata when playback stops. Remote command handlers
    /// remain registered for the lifetime of the app service graph, so a later
    /// playback session remains controllable without re-registering targets.
    func stop() async

    /// Late-wired dependency for the remote like command — FavoritesService is built after this
    /// service in AppContainer.
    func setFavoritesService(_ service: any FavoritesServiceProtocol) async

    /// Pushes a full metadata + artwork update (called from PlayerService on track change or seek).
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
