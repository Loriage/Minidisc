import AppIntents
import Foundation

struct MinidiscMusicEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Music"
    static let defaultQuery = MinidiscMusicQuery()
    let id: String
    @Property(title: "Title") var title: String
    @Property(title: "Artist") var artist: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(artist)", image: .init(systemName: symbol))
    }

    private var symbol: String {
        switch MusicIntentID(rawValue: id)?.kind {
        case .album: "square.stack"
        case .artist: "music.mic"
        case .playlist: "music.note.list"
        default: "music.note"
        }
    }

    init(record: MusicIntentRecord) {
        id = record.id
        title = record.title
        artist = record.subtitle
    }
}

struct MinidiscMusicQuery: EntityStringQuery {
    @Dependency private var runtime: MinidiscRuntime

    @MainActor
    func entities(for identifiers: [String]) async throws -> [MinidiscMusicEntity] {
        let service = MusicIntentService(container: try await runtime.container())
        return try await service.resolve(identifiers).map(MinidiscMusicEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [MinidiscMusicEntity] {
        let service = MusicIntentService(container: try await runtime.container())
        return try await service.search(string).map(MinidiscMusicEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [MinidiscMusicEntity] {
        let service = MusicIntentService(container: try await runtime.container())
        return try await service.suggestions().map(MinidiscMusicEntity.init)
    }
}

extension Mood: AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Mood"
    static let caseDisplayRepresentations: [Mood: DisplayRepresentation] = [
        .night: "Night", .energetic: "Energetic", .workout: "Workout", .chill: "Chill", .focus: "Focus"
    ]
}
