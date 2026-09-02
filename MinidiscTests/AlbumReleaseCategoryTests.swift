import Testing
import SwiftSonic
@testable import Minidisc

struct AlbumReleaseCategoryTests {
    @Test("OpenSubsonic singles and EPs use the dedicated artist shelf", arguments: [
        ["Single"],
        ["EP"],
        ["Extended Play"],
        ["Album", "Single"]
    ])
    func singlesAndEPs(releaseTypes: [String]) {
        #expect(album(releaseTypes: releaseTypes).minidiscReleaseCategory == .singleOrEP)
    }

    @Test("Albums and missing release metadata stay in the album shelf", arguments: [
        nil,
        [],
        ["Album"],
        ["Live"]
    ] as [[String]?])
    func albums(releaseTypes: [String]?) {
        #expect(album(releaseTypes: releaseTypes).minidiscReleaseCategory == .album)
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
