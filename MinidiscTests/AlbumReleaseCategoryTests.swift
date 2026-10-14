import Testing
import SwiftSonic
@testable import Minidisc

struct AlbumReleaseCategoryTests {
    @Test("Release types map to their discography shelf", arguments: [
        (["Single"], AlbumReleaseCategory.single),
        (["Album", "Single"], .single),
        (["EP"], .ep),
        (["Extended Play"], .ep),
        (["EP", "Single"], .ep),
        (["Album", "Live"], .live),
        (["Live"], .live),
        (["Single", "Live"], .live),
        (["Album", "Compilation"], .compilation),
        (["Album", "Soundtrack"], .other),
        (["Album/Remix"], .other)
    ] as [([String], AlbumReleaseCategory)])
    func releaseTypes(types: [String], expected: AlbumReleaseCategory) {
        #expect(album(releaseTypes: types).minidiscReleaseCategory == expected)
    }

    @Test("Albums and missing release metadata stay in the album shelf", arguments: [
        nil,
        [],
        ["Album"]
    ] as [[String]?])
    func albums(releaseTypes: [String]?) {
        #expect(album(releaseTypes: releaseTypes).minidiscReleaseCategory == .album)
    }

    @Test func compilationFlag_withoutReleaseTypes_isCompilation() {
        #expect(AlbumReleaseCategory.category(releaseTypes: nil, isCompilation: true) == .compilation)
    }

    private func album(releaseTypes: [String]?) -> AlbumID3 {
        AlbumID3(
            id: "release",
            name: "Release",
            songCount: 1,
            duration: 180,
            releaseTypes: releaseTypes
        )
    }
}
