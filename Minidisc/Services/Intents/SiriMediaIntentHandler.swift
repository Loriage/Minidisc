import Intents
import UIKit

extension MinidiscAppDelegate {
    func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
        intent is INPlayMediaIntent || intent is INSearchForMediaIntent ? SiriMediaIntentHandler() : nil
    }
}

@MainActor
final class SiriMediaIntentHandler: NSObject, INPlayMediaIntentHandling, INSearchForMediaIntentHandling {
    private let runtime: MinidiscRuntime

    init(runtime: MinidiscRuntime = .shared) {
        self.runtime = runtime
    }

    func handle(intent: INSearchForMediaIntent) async -> INSearchForMediaIntentResponse {
        runtime.diagnostics.record(.musicIntent(.siriKitSearch))
        do {
            let container = try await runtime.container()
            let request = INPlayMediaIntent(mediaItems: intent.mediaItems, mediaContainer: nil,
                                            playShuffled: nil, playbackRepeatMode: .unknown, resumePlayback: nil,
                                            playbackQueueLocation: .unknown, playbackSpeed: nil, mediaSearch: intent.mediaSearch)
            let records = try await candidates(for: request, container: container)
            let response = INSearchForMediaIntentResponse(code: .success, userActivity: nil)
            response.mediaItems = records.map(Self.mediaItem)
            return response
        } catch MusicIntentError.noServer, MusicIntentError.differentServer {
            return .init(code: .failureRequiringAppLaunch, userActivity: nil)
        } catch {
            return .init(code: .failure, userActivity: nil)
        }
    }

    func resolveMediaItems(for intent: INPlayMediaIntent) async -> [INPlayMediaMediaItemResolutionResult] {
        runtime.diagnostics.record(.musicIntent(.siriKitResolution))
        do {
            let container = try await runtime.container()
            guard container.serverState.activeServer != nil else { return [.unsupported(forReason: .loginRequired)] }
            if Self.isResumeOrGeneric(intent) { return [.notRequired()] }
            let records = try await candidates(for: intent, container: container)
            guard !records.isEmpty else { return [.unsupported()] }
            let items = records.prefix(5).map(Self.mediaItem)
            if items.count == 1 { return [.success(with: items[0])] }
            return [.disambiguation(with: items)]
        } catch MusicIntentError.noServer {
            return [.unsupported(forReason: .loginRequired)]
        } catch {
            return [.unsupported(forReason: .serviceUnavailable)]
        }
    }

    func handle(intent: INPlayMediaIntent) async -> INPlayMediaIntentResponse {
        runtime.diagnostics.record(.musicIntent(.siriKitPlayback))
        do {
            let container = try await runtime.container()
            guard container.serverState.activeServer != nil else {
                return .init(code: .failureRequiringAppLaunch, userActivity: nil)
            }
            if Self.isResumeOrGeneric(intent) {
                if container.playerState.currentTrack != nil || container.playerState.currentRadio != nil {
                    await container.playerService.resume()
                } else if intent.resumePlayback == true {
                    return .init(code: .failureNoUnplayedContent, userActivity: nil)
                } else {
                    try await container.playerService.playSmartShuffle()
                }
            } else {
                let records = try await candidates(for: intent, container: container)
                // Resolution must select a single collection or song; never silently choose among ambiguous results.
                guard records.count == 1, let record = records.first else {
                    return .init(code: .failure, userActivity: nil)
                }
                let service = MusicIntentService(container: container)
                switch intent.playbackQueueLocation {
                case .next, .later:
                    try await service.enqueue(id: record.id, next: intent.playbackQueueLocation == .next,
                                              shuffle: intent.playShuffled == true)
                default:
                    try await service.play(id: record.id, shuffle: intent.playShuffled == true,
                                           repeatMode: Self.repeatMode(intent.playbackRepeatMode))
                }
            }
            return .init(code: .success, userActivity: nil)
        } catch MusicIntentError.noServer, MusicIntentError.differentServer {
            return .init(code: .failureRequiringAppLaunch, userActivity: nil)
        } catch {
            return .init(code: .failure, userActivity: nil)
        }
    }

    private func candidates(for intent: INPlayMediaIntent, container: AppContainer) async throws -> [MusicIntentRecord] {
        let service = MusicIntentService(container: container)
        let identifiers = Self.identifiers(for: intent)
        if !identifiers.isEmpty {
            // Never reinterpret a stale Minidisc selection against another account.
            return try await service.resolve(identifiers)
        }
        if (intent.mediaItems ?? []).contains(where: { $0.identifier != nil }) ||
            intent.mediaContainer?.identifier != nil || intent.mediaSearch?.mediaIdentifier != nil {
            runtime.diagnostics.record(.musicIntent(.unrecognizedMediaIdentifier))
        }
        let search = intent.mediaSearch
        let term = Self.term(for: intent)
        guard !term.isEmpty || search?.mediaType == .playlist else { return [] }
        let records: [MusicIntentRecord]
        if search?.mediaType == .playlist { records = try await service.searchPlaylists(term) }
        else { records = try await service.search(term) }
        return Self.filter(records, search: search, term: term)
    }

    static func identifiers(for intent: INPlayMediaIntent) -> [String] {
        let items = (intent.mediaItems ?? []).compactMap(\.identifier).filter { MusicIntentID(rawValue: $0) != nil }
        if !items.isEmpty { return items }
        if let identifier = [intent.mediaContainer?.identifier, intent.mediaSearch?.mediaIdentifier]
            .compactMap({ $0 }).first(where: { MusicIntentID(rawValue: $0) != nil }) { return [identifier] }
        return []
    }

    static func term(for intent: INPlayMediaIntent) -> String {
        [intent.mediaSearch?.mediaName, intent.mediaSearch?.albumName, intent.mediaSearch?.artistName,
         intent.mediaItems?.first?.title, intent.mediaContainer?.title]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? ""
    }

    static func isResumeOrGeneric(_ intent: INPlayMediaIntent) -> Bool {
        guard term(for: intent).isEmpty, (intent.mediaItems ?? []).isEmpty,
              intent.mediaContainer == nil, intent.mediaSearch?.mediaIdentifier == nil,
              (intent.mediaSearch?.genreNames ?? []).isEmpty, (intent.mediaSearch?.moodNames ?? []).isEmpty else { return false }
        let kind = intent.mediaSearch?.mediaType ?? .unknown
        return kind == .unknown || kind == .music
    }

    static func filter(_ records: [MusicIntentRecord], search: INMediaSearch?, term: String) -> [MusicIntentRecord] {
        let type = search?.mediaType ?? .unknown
        let matching = records.filter { record in
            let typeMatches: Bool
            switch type {
            case .song: typeMatches = record.reference.kind == .song
            case .album: typeMatches = record.reference.kind == .album
            case .artist: typeMatches = record.reference.kind == .artist
            case .playlist: typeMatches = record.reference.kind == .playlist
            case .unknown, .music: typeMatches = true
            default: typeMatches = false
            }
            guard typeMatches else { return false }
            if let artist = search?.artistName, !artist.isEmpty,
               record.reference.kind == .song || record.reference.kind == .album,
               !record.subtitle.localizedStandardContains(artist) { return false }
            if let album = search?.albumName, !album.isEmpty, record.reference.kind == .song,
               record.song?.albumName?.localizedStandardContains(album) != true { return false }
            return true
        }
        let exact = matching.filter { MusicIntentService.matchRank($0.title, term: term) == 0 }
        return exact.isEmpty ? matching : exact
    }

    static func mediaItem(_ record: MusicIntentRecord) -> INMediaItem {
        let type: INMediaItemType
        switch record.reference.kind {
        case .song: type = .song
        case .album: type = .album
        case .artist: type = .artist
        case .playlist: type = .playlist
        }
        return INMediaItem(identifier: record.id, title: record.title, type: type, artwork: nil, artist: record.subtitle)
    }

    static func repeatMode(_ mode: INPlaybackRepeatMode) -> RepeatMode? {
        switch mode {
        case .none: .off
        case .all: .all
        case .one: .one
        default: nil
        }
    }
}
