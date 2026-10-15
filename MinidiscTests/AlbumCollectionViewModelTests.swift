import Foundation
import Testing
import SwiftSonic
@testable import Minidisc

@Suite("Album collections")
@MainActor
struct AlbumCollectionViewModelTests {

    @Test func genre_loadsAlbumsSortedByName() async {
        let library = CollectionLibraryStub()
        library.genreAlbums = [album("b", "Zebra"), album("a", "apple"), album("c", "Mango")]
        let vm = AlbumCollectionViewModel(kind: .genre("Jazz"), library: library)
        await vm.load()
        #expect(vm.state == .loaded)
        #expect(vm.albums.map(\.name) == ["apple", "Mango", "Zebra"])
        #expect(library.requestedGenre == "Jazz")
    }

    @Test func label_withIncompleteIndex_waitsForIndex() async {
        let library = CollectionLibraryStub()
        library.labelAlbums = nil
        let vm = AlbumCollectionViewModel(kind: .recordLabel("Riverside"), library: library)
        await vm.load()
        #expect(vm.state == .waitingForIndex)
        #expect(vm.albums.isEmpty)
    }

    @Test func failure_mapsToUserFacingError() async {
        let library = CollectionLibraryStub()
        library.error = URLError(.notConnectedToInternet)
        let vm = AlbumCollectionViewModel(kind: .genre("Jazz"), library: library)
        await vm.load()
        #expect(vm.state == .failed(.noNetwork))
    }

    private func album(_ id: String, _ name: String) -> AlbumID3 {
        AlbumID3(id: id, name: name, songCount: 1, duration: 60)
    }
}

@MainActor
private final class CollectionLibraryStub: GenreBrowsing, RecordLabelBrowsing {
    var genreAlbums: [AlbumID3] = []
    var labelAlbums: [AlbumID3]? = []
    var error: (any Error)?
    var requestedGenre: String?

    func genres() async throws -> [Genre] { [] }

    @MainActor
    func albumsByGenre(_ genre: String, size: Int) async throws -> [AlbumID3] {
        requestedGenre = genre
        if let error { throw error }
        return genreAlbums
    }

    @MainActor
    func albums(recordLabel: String) async throws -> [AlbumID3]? {
        if let error { throw error }
        return labelAlbums
    }
}
