import Foundation
import Testing
@testable import Minidisc

@Suite("Queue track selection")
@MainActor
struct QueueTrackSelectionTests {
    @Test("resolves while the captured queue is unchanged")
    func resolvesCurrentSnapshot() throws {
        let state = makePlayerState(queue: [makeSong("one"), makeSong("two"), makeSong("three")], currentIndex: 1)
        let selection = try #require(
            QueueTrackSelection(playerState: state, destinationIndex: 2, destinationTrackID: "three")
        )

        #expect(selection.resolve(in: state) == 2)
    }

    @Test("rejects invalid or current destinations")
    func rejectsInvalidDestination() {
        let state = makePlayerState(queue: [makeSong("one"), makeSong("two")], currentIndex: 0)

        #expect(QueueTrackSelection(playerState: state, destinationIndex: 0, destinationTrackID: "one") == nil)
        #expect(QueueTrackSelection(playerState: state, destinationIndex: 2, destinationTrackID: "missing") == nil)
        #expect(QueueTrackSelection(playerState: state, destinationIndex: 1, destinationTrackID: "wrong") == nil)
    }

    @Test("rejects a request after the queue changes")
    func rejectsChangedQueue() throws {
        let state = makePlayerState(queue: [makeSong("one"), makeSong("two"), makeSong("three")], currentIndex: 0)
        let selection = try #require(
            QueueTrackSelection(playerState: state, destinationIndex: 1, destinationTrackID: "two")
        )

        state.queue.swapAt(1, 2)

        #expect(selection.resolve(in: state) == nil)
    }

    @Test("rejects a request from a previous queue generation")
    func rejectsChangedGeneration() throws {
        let state = makePlayerState(queue: [makeSong("one"), makeSong("two")], currentIndex: 0)
        let selection = try #require(
            QueueTrackSelection(playerState: state, destinationIndex: 1, destinationTrackID: "two")
        )

        state.queueGeneration &+= 1

        #expect(selection.resolve(in: state) == nil)
    }

    @Test("keeps duplicate queue entries addressable by index")
    func supportsDuplicateSongs() throws {
        let duplicate = makeSong("duplicate")
        let state = makePlayerState(queue: [duplicate, duplicate], currentIndex: 0)
        let selection = try #require(
            QueueTrackSelection(playerState: state, destinationIndex: 1, destinationTrackID: "duplicate")
        )

        #expect(selection.resolve(in: state) == 1)
    }
}

@Suite("Track swipe destinations")
@MainActor
struct TrackSwipeInteractionTests {
    @Test("exposes adjacent queue items")
    func exposesAdjacentItems() {
        let state = makePlayerState(
            queue: [makeSong("one"), makeSong("two"), makeSong("three")],
            currentIndex: 1
        )
        let interaction = TrackSwipeInteraction()

        #expect(interaction.destination(.previous, in: state)?.song.id == "one")
        #expect(interaction.destination(.next, in: state)?.song.id == "three")
    }

    @Test("respects queue boundaries and wraps next only in Repeat All")
    func respectsBoundaries() {
        let state = makePlayerState(queue: [makeSong("one"), makeSong("two")], currentIndex: 1)
        let interaction = TrackSwipeInteraction()

        #expect(interaction.destination(.next, in: state) == nil)

        state.repeatMode = .all
        #expect(interaction.destination(.next, in: state)?.song.id == "one")

        state.currentIndex = 0
        state.currentTrack = state.queue[0]
        #expect(interaction.destination(.previous, in: state) == nil)
    }
}

@MainActor
private func makePlayerState(queue: [DisplayableSong], currentIndex: Int) -> PlayerState {
    let state = PlayerState()
    state.queue = queue
    state.currentIndex = currentIndex
    state.currentTrack = queue[currentIndex]
    state.queueGeneration = 42
    return state
}

private func makeSong(_ id: String) -> DisplayableSong {
    DisplayableSong(
        id: id,
        title: id.capitalized,
        artist: "Artist",
        albumId: "album",
        albumName: "Album",
        artistId: "artist",
        genre: nil,
        duration: 180,
        trackNumber: 1,
        isDownloaded: false,
        coverArtId: id,
        audioFormat: "FLAC",
        replayGainTrackGain: nil,
        replayGainTrackPeak: nil,
        replayGainAlbumGain: nil,
        replayGainAlbumPeak: nil,
        replayGainBaseGain: nil,
        replayGainFallbackGain: nil
    )
}
