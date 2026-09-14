#if compiler(>=6.4) && canImport(MediaIntents)
import AppIntents
import MediaIntents

@available(iOS 27.0, *)
@AppEntity(schema: .audio.artist)
struct SiriArtistEntity {
    static let defaultQuery = SiriArtistEntityQuery()
    let id: String
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: "music.mic"))
    }

    init(record: MusicIntentRecord) {
        id = record.id
        name = record.title
    }
}

@available(iOS 27.0, *)
struct SiriArtistEntityQuery: EntityStringQuery {
    @Dependency private var runtime: MinidiscRuntime

    @MainActor
    func entities(for identifiers: [String]) async throws -> [SiriArtistEntity] {
        let service = MusicIntentService(container: try await runtime.container())
        return try await service.resolve(identifiers).filter { $0.reference.kind == .artist }.map(SiriArtistEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [SiriArtistEntity] {
        let service = MusicIntentService(container: try await runtime.container())
        return try await service.search(string).filter { $0.reference.kind == .artist }.map(SiriArtistEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [SiriArtistEntity] {
        let service = MusicIntentService(container: try await runtime.container())
        return try await service.suggestions().filter { $0.reference.kind == .artist }.map(SiriArtistEntity.init)
    }
}

@available(iOS 27.0, *)
@AppEntity(schema: .audio.album)
struct SiriAlbumEntity {
    static let defaultQuery = SiriAlbumEntityQuery()
    let id: String
    var title: String
    var artistName: String
    var artists: [SiriArtistEntity]
    var universalProductCode: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(artistName)", image: .init(systemName: "square.stack"))
    }

    init(record: MusicIntentRecord) {
        id = record.id
        title = record.title
        artistName = record.subtitle
        artists = []
    }
}

@available(iOS 27.0, *)
struct SiriAlbumEntityQuery: EntityStringQuery {
    @Dependency private var runtime: MinidiscRuntime

    @MainActor
    func entities(for identifiers: [String]) async throws -> [SiriAlbumEntity] {
        let service = MusicIntentService(container: try await runtime.container())
        return try await service.resolve(identifiers).filter { $0.reference.kind == .album }.map(SiriAlbumEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [SiriAlbumEntity] {
        let service = MusicIntentService(container: try await runtime.container())
        return try await service.search(string).filter { $0.reference.kind == .album }.map(SiriAlbumEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [SiriAlbumEntity] {
        let service = MusicIntentService(container: try await runtime.container())
        return try await service.suggestions().filter { $0.reference.kind == .album }.map(SiriAlbumEntity.init)
    }
}

@available(iOS 27.0, *)
@AppEntity(schema: .audio.song)
struct SiriSongEntity {
    static let defaultQuery = SiriSongEntityQuery()
    let id: String
    var title: String
    var artistName: String
    var artists: [SiriArtistEntity]
    var albumTitle: String?
    var album: SiriAlbumEntity?
    var composerName: String?
    var composers: [SiriArtistEntity]
    var internationalStandardRecordingCode: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(artistName)", image: .init(systemName: "music.note"))
    }

    init(record: MusicIntentRecord) {
        id = record.id
        title = record.title
        artistName = record.subtitle
        artists = []
        albumTitle = record.song?.albumName
        composers = []
    }
}

@available(iOS 27.0, *)
struct SiriSongEntityQuery: EntityStringQuery {
    @Dependency private var runtime: MinidiscRuntime

    @MainActor
    func entities(for identifiers: [String]) async throws -> [SiriSongEntity] {
        let service = MusicIntentService(container: try await runtime.container())
        return try await service.resolve(identifiers).filter { $0.reference.kind == .song }.map(SiriSongEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [SiriSongEntity] {
        let service = MusicIntentService(container: try await runtime.container())
        return try await service.search(string).filter { $0.reference.kind == .song }.map(SiriSongEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [SiriSongEntity] {
        let service = MusicIntentService(container: try await runtime.container())
        return try await service.suggestions().filter { $0.reference.kind == .song }.map(SiriSongEntity.init)
    }
}

@available(iOS 27.0, *)
@AppEntity(schema: .audio.playlist)
struct SiriPlaylistEntity {
    static let defaultQuery = SiriPlaylistEntityQuery()
    let id: String
    var title: String
    var owner: SiriPlaylistOwner?
    var createdByMe: Bool?
    var curatedForMe: Bool?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", image: .init(systemName: "music.note.list"))
    }

    init(record: MusicIntentRecord) {
        id = record.id
        title = record.title
        curatedForMe = Mood.allCases.contains { $0.playlistName == record.title } ? true : nil
    }
}

@available(iOS 27.0, *)
struct SiriPlaylistEntityQuery: EntityStringQuery {
    @Dependency private var runtime: MinidiscRuntime

    @MainActor
    func entities(for identifiers: [String]) async throws -> [SiriPlaylistEntity] {
        let service = MusicIntentService(container: try await runtime.container())
        return try await service.resolve(identifiers).filter { $0.reference.kind == .playlist }.map(SiriPlaylistEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [SiriPlaylistEntity] {
        let service = MusicIntentService(container: try await runtime.container())
        return try await service.searchPlaylists(string).map(SiriPlaylistEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [SiriPlaylistEntity] {
        let service = MusicIntentService(container: try await runtime.container())
        return try await service.suggestions().filter { $0.reference.kind == .playlist }.map(SiriPlaylistEntity.init)
    }
}

@available(iOS 27.0, *)
@AppEnum(schema: .audio.playbackAttributes)
enum SiriPlaybackAttribute: String {
    case shuffle
    case `repeat`
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .shuffle: "Shuffle", .repeat: "Repeat"
    ]
}

@available(iOS 27.0, *)
@UnionValue
enum SiriMusicItem: Sendable {
    case song(SiriSongEntity)
    case album(SiriAlbumEntity)
    case artist(SiriArtistEntity)
    case playlist(SiriPlaylistEntity)
}

@available(iOS 27.0, *)
nonisolated extension SiriMusicItem {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Music" }
    static let caseDisplayRepresentations: [Cases: DisplayRepresentation] = [
        .song: "Song", .album: "Album", .artist: "Artist", .playlist: "Playlist"
    ]

    var id: String {
        switch self {
        case .song(let item): item.id
        case .album(let item): item.id
        case .artist(let item): item.id
        case .playlist(let item): item.id
        }
    }

    init(record: MusicIntentRecord) {
        switch record.reference.kind {
        case .song: self = .song(SiriSongEntity(record: record))
        case .album: self = .album(SiriAlbumEntity(record: record))
        case .artist: self = .artist(SiriArtistEntity(record: record))
        case .playlist: self = .playlist(SiriPlaylistEntity(record: record))
        }
    }
}

@available(iOS 27.0, *)
struct SiriMusicSearchQuery: IntentValueQuery {
    @Dependency private var runtime: MinidiscRuntime

    @MainActor
    func values(for input: AudioSearch) async throws -> [SiriMusicItem] {
        runtime.diagnostics.record(.musicIntent(.audioSearch))
        let service = MusicIntentService(container: try await runtime.container())
        switch input.criteria {
        case .searchQuery(let text): return try await service.search(text).map(SiriMusicItem.init)
        case .unspecified: return try await service.suggestions().map(SiriMusicItem.init)
        case .url: return []
        @unknown default: return []
        }
    }
}

@available(iOS 27.0, *)
@AppEnum(schema: .audio.queueInsertionLocation)
enum SiriQueueLocation: String {
    case next
    case tail
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .next: "Play Next", .tail: "Add to Queue"
    ]
}

@available(iOS 27.0, *)
@UnionValue
enum SiriPlaylistOwner: Sendable {
    case curator(String)
    case person(IntentPerson)
}

@available(iOS 27.0, *)
@AppEntity(schema: .audio.warmupAudioQueueResult)
struct SiriAudioWarmup: TransientAppEntity {
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "Music") }
}

@available(iOS 27.0, *)
@AppIntent(schema: .audio.playAudio)
struct PlaySiriAudioIntent: AudioPlaybackIntent {
    static var supportedModes: IntentModes { .background }
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
    var audioEntity: SiriMusicItem
    @Parameter(default: [])
    var playbackAttributes: Set<SiriPlaybackAttribute>
    var warmupAudioQueueResult: SiriAudioWarmup?
    var queueLocation: SiriQueueLocation?
    @Dependency private var runtime: MinidiscRuntime

    @MainActor
    func perform() async throws -> some IntentResult {
        runtime.diagnostics.record(.musicIntent(.audioPlayback))
        let container = try await runtime.container()
        let service = MusicIntentService(container: container)
        switch queueLocation {
        case .none:
            try await service.play(id: audioEntity.id, shuffle: playbackAttributes.contains(.shuffle),
                                   repeatMode: playbackAttributes.contains(.repeat) ? .all : nil)
        case .next:
            try await service.enqueue(id: audioEntity.id, next: true, shuffle: playbackAttributes.contains(.shuffle))
        case .tail:
            try await service.enqueue(id: audioEntity.id, next: false, shuffle: playbackAttributes.contains(.shuffle))
        }
        return .result()
    }
}
#endif
