import Foundation
import SwiftSonic
import OSLog

/// What an album collection page gathers: every album in a genre, or from a record label.
nonisolated enum AlbumCollectionKind: Hashable, Sendable {
    case genre(String)
    case recordLabel(String)

    var name: String {
        switch self {
        case .genre(let name), .recordLabel(let name): name
        }
    }

    var systemImage: String {
        switch self {
        case .genre: "music.note.list"
        case .recordLabel: "building.2"
        }
    }
}

@Observable
@MainActor
final class AlbumCollectionViewModel {
    enum LoadState: Equatable {
        case loading
        case loaded
        /// Label pages need the complete album index; the server cannot filter by label.
        case waitingForIndex
        case failed(UserFacingError)
    }

    let kind: AlbumCollectionKind
    private(set) var albums: [AlbumID3] = []
    private(set) var state: LoadState = .loading
    var isPlayLoading = false

    private let library: any GenreBrowsing & RecordLabelBrowsing
    /// The Subsonic getAlbumList2 maximum page size.
    private static let genreAlbumLimit = 500

    init(kind: AlbumCollectionKind, library: any GenreBrowsing & RecordLabelBrowsing) {
        self.kind = kind
        self.library = library
    }

    func load() async {
        if albums.isEmpty { state = .loading }
        do {
            let loaded: [AlbumID3]?
            switch kind {
            case .genre(let genre):
                loaded = try await library.albumsByGenre(genre, size: Self.genreAlbumLimit)
            case .recordLabel(let label):
                loaded = try await library.albums(recordLabel: label)
            }
            try Task.checkCancellation()
            guard let loaded else {
                state = .waitingForIndex
                return
            }
            albums = loaded.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            state = .loaded
        } catch is CancellationError {
            return
        } catch {
            Logger.library.warning("Album collection failed: \(error, privacy: .public)")
            state = .failed(UserFacingError.from(error))
        }
    }
}
