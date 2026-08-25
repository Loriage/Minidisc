import Foundation
import SwiftSonic
import Testing
@testable import Minidisc

private enum LibraryStubBehavior: Sendable {
    case cancellation
    case failure
    case songs([DisplayableSong])
}

private enum LibraryStubError: Error {
    case unavailable
}

private actor EndlessExtensionLibraryStub: PlaybackQueueBuilding {
    private let instantMixBehavior: LibraryStubBehavior
    private let backfillBehavior: LibraryStubBehavior
    private var backfillCalls = 0

    init(
        instantMixBehavior: LibraryStubBehavior,
        backfillBehavior: LibraryStubBehavior
    ) {
        self.instantMixBehavior = instantMixBehavior
        self.backfillBehavior = backfillBehavior
    }

    func instantMix(from seed: InstantMixSeed, count: Int) async throws -> [DisplayableSong] {
        try Self.resolve(instantMixBehavior)
    }

    func similarBackfillQueue(
        targetSize: Int,
        excludedIds: Set<String>
    ) async throws -> [DisplayableSong] {
        backfillCalls += 1
        return try Self.resolve(backfillBehavior)
    }

    func backfillCallCount() -> Int {
        backfillCalls
    }

    private nonisolated static func resolve(
        _ behavior: LibraryStubBehavior
    ) throws -> [DisplayableSong] {
        switch behavior {
        case .cancellation:
            throw CancellationError()
        case .failure:
            throw LibraryStubError.unavailable
        case .songs(let songs):
            return songs
        }
    }

    func smartShuffleQueue(targetSize: Int) async throws -> [DisplayableSong] { [] }
}

@Suite("Library cancellation propagation")
struct LibraryCancellationTests {
    @Test("Instant-mix cancellation is not converted into an empty best-effort result")
    func instantMixCancellationPropagates() async {
        let library = EndlessExtensionLibraryStub(
            instantMixBehavior: .cancellation,
            backfillBehavior: .songs([])
        )

        await #expect(throws: CancellationError.self) {
            try await library.endlessExtension(
                seedTrackId: "seed",
                targetSize: 20,
                excludedIds: []
            )
        }
        #expect(await library.backfillCallCount() == 0)
    }

    @Test("Backfill cancellation is not swallowed after an ordinary instant-mix failure")
    func backfillCancellationPropagates() async {
        let library = EndlessExtensionLibraryStub(
            instantMixBehavior: .failure,
            backfillBehavior: .cancellation
        )

        await #expect(throws: CancellationError.self) {
            try await library.endlessExtension(
                seedTrackId: "seed",
                targetSize: 20,
                excludedIds: []
            )
        }
        #expect(await library.backfillCallCount() == 1)
    }

    @Test("Ordinary provider failures retain best-effort fallback semantics")
    func ordinaryFailuresRemainBestEffort() async throws {
        let library = EndlessExtensionLibraryStub(
            instantMixBehavior: .failure,
            backfillBehavior: .failure
        )

        let result = try await library.endlessExtension(
            seedTrackId: "seed",
            targetSize: 20,
            excludedIds: []
        )

        #expect(result.isEmpty)
        #expect(await library.backfillCallCount() == 1)
    }
}
