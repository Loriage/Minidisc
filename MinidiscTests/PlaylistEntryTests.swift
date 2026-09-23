import Foundation
import Testing
import SwiftSonic
@testable import Minidisc

@Suite struct PlaylistEntryTests {
    private func songs(_ ids: [String]) -> [DisplayableSong] {
        ids.map { DisplayableSong(from: Song(id: $0, title: $0)) }
    }

    @Test func selectingTheLastDuplicateStartsAtThatOccurrence() throws {
        let songs = songs(["a", "b", "a"])
        let entries = PlaylistEntry.make(songs)
        #expect(Set(entries.map(\.id)).count == 3)
        let queue = try #require(PlaylistEntry.playbackQueue(requested: entries, selectedID: entries[2].id, available: songs))
        #expect(queue.startIndex == 2)
        #expect(queue.tracks.map(\.id) == ["a", "b", "a"])
    }

    @Test func sortingAndFilteringKeepTheSelectedOccurrence() throws {
        let original = PlaylistEntry.make(songs(["a", "b", "a"]))
        let reordered = [original[1], original[2], original[0]]
        #expect(reordered[1].sourceIndex == 2)
        let queue = try #require(PlaylistEntry.playbackQueue(requested: reordered,
            selectedID: original[2].id, available: songs(["a", "a"])))
        #expect(queue.startIndex == 0)
        #expect(queue.tracks.map(\.id) == ["a", "a"])
        #expect(PlaylistEntry.playbackQueue(requested: original, selectedID: original[2].id, available: songs(["a", "b"])) == nil)
    }

    @Test func editingOneOccurrenceKeepsOtherOccurrencesAndTheirIdentities() {
        let original = PlaylistEntry.make(songs(["a", "b", "a"]))
        let selected = Set([original[0].id])
        var draft = original.filter { !selected.contains($0.id) }
        draft.reverse()
        draft = PlaylistEntry.appending(songs(["a"]), to: draft)
        #expect(draft.map(\.song.id) == ["a", "b", "a"])
        #expect(draft[0].id == original[2].id)
        #expect(Set(draft.map(\.id)).count == draft.count)
    }
}
