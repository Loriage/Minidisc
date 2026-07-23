// Minidisc — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import OSLog

// All properties are `nonisolated` to prevent SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor
// from implicitly isolating them, which would cause concurrency warnings when accessed
// from non-MainActor contexts (actors, background tasks, etc.). Logger is Sendable.
extension Logger {
    nonisolated static let server     = Logger(subsystem: "app.minidisc.server",     category: "ServerService")
    nonisolated static let player     = Logger(subsystem: "app.minidisc.player",     category: "PlayerService")
    nonisolated static let library    = Logger(subsystem: "app.minidisc.library",    category: "LibraryService")
    nonisolated static let cache      = Logger(subsystem: "app.minidisc.cache",      category: "AudioStreamCache")
    nonisolated static let download   = Logger(subsystem: "app.minidisc.download",   category: "DownloadService")
    nonisolated static let resolver   = Logger(subsystem: "app.minidisc.resolver",   category: "MediaResolver")
    nonisolated static let nowPlaying = Logger(subsystem: "app.minidisc.nowplaying", category: "NowPlayingService")
    nonisolated static let keychain   = Logger(subsystem: "app.minidisc.keychain",   category: "KeychainService")
    nonisolated static let network     = Logger(subsystem: "app.minidisc.network",    category: "NetworkMonitor")
    nonisolated static let ui         = Logger(subsystem: "app.minidisc.ui",         category: "UI")
    nonisolated static let favorites   = Logger(subsystem: "app.minidisc.favorites",  category: "FavoritesService")
    nonisolated static let pin         = Logger(subsystem: "app.minidisc.pin",        category: "PinService")
    nonisolated static let session     = Logger(subsystem: "app.minidisc.session",    category: "PlaybackSessionService")
    nonisolated static let playlist    = Logger(subsystem: "app.minidisc.playlist",   category: "PlaylistService")
    nonisolated static let radio       = Logger(subsystem: "app.minidisc.radio",      category: "RadioService")
    nonisolated static let discover      = Logger(subsystem: "app.minidisc.discover",      category: "DiscoverViewModel")
    nonisolated static let dominantColor = Logger(subsystem: "app.minidisc.dominantColor", category: "DominantColorExtractor")
    nonisolated static let stats         = Logger(subsystem: "app.minidisc.stats",         category: "StatsService")
    nonisolated static let wrapped       = Logger(subsystem: "app.minidisc.wrapped",       category: "WrappedPlaylistService")
    nonisolated static let wrappedStory  = Logger(subsystem: "app.minidisc.wrappedstory",  category: "WrappedStoryPlayer")
    nonisolated static let lyrics        = Logger(subsystem: "app.minidisc.lyrics",        category: "LyricsService")
    nonisolated static let moodPlaylists = Logger(subsystem: "app.minidisc.moodplaylists", category: "MoodPlaylistService")
    nonisolated static let recommendations  = Logger(subsystem: "app.minidisc.recommendations",  category: "RecommendationService")
    nonisolated static let listenBrainz     = Logger(subsystem: "app.minidisc.listenbrainz",     category: "ListenBrainz")
    nonisolated static let integrations       = Logger(subsystem: "app.minidisc.integrations",       category: "Integrations")
    nonisolated static let externalArtwork    = Logger(subsystem: "app.minidisc.externalartwork",    category: "ExternalArtworkCache")
    nonisolated static let artistArtwork      = Logger(subsystem: "app.minidisc.artistartwork",      category: "ExternalArtistImageResolver")
    nonisolated static let httpTransport      = Logger(subsystem: "app.minidisc.transport",          category: "CustomHeadersTransport")
    nonisolated static let artworkCache       = Logger(subsystem: "app.minidisc.artworkcache",       category: "ArtworkCache")
    nonisolated static let boot               = Logger(subsystem: "app.minidisc.boot",               category: "Boot")
    nonisolated static let migration          = Logger(subsystem: "app.minidisc.migration",          category: "Migration")
}
