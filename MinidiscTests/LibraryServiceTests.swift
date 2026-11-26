import Testing
import Foundation
@testable import Minidisc

@Suite("LibraryService — normalizeArtistName")
struct LibraryServiceNormalizationTests {

    @Test("lowercases ASCII")
    func lowercases() {
        #expect(LibraryService.normalizeArtistName("JAY-Z") == "jay-z")
    }

    @Test("combines lowercasing, diacritics folding and trimming")
    func combined() {
        #expect(LibraryService.normalizeArtistName(" Sigur Rós ") == "sigur ros")
        #expect(LibraryService.normalizeArtistName("  Björk  ") == "bjork")
    }

    @Test("already-normalized string is unchanged")
    func idempotent() {
        let normalized = "the beatles"
        #expect(LibraryService.normalizeArtistName(normalized) == normalized)
    }
}
