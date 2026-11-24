import Foundation
import Testing
@testable import Minidisc

@Suite("Lidarr artist shortcut")
struct LidarrArtistResolverTests {
    private let mbid = "b071f9fa-14b0-4217-8e97-eb41da73f598"
    private let otherMBID = "8b9c9b26-f7c2-4ba1-917c-d09a23f4d6d1"

    @Test(arguments: [nil, "", "  ", "not-an-mbid"] as [String?])
    func missingIdentifierFallsBackWithoutRequest(mbid: String?) async throws {
        let client = LookupClient(results: [])
        guard case .search = try await LidarrArtistResolver.resolve(mbid: mbid, using: client) else {
            Issue.record("Expected manual search")
            return
        }
        #expect(await client.queries.isEmpty)
    }

    @Test(arguments: [nil, 0] as [Int?])
    func exactIdentifierSelectsTheArtistRegardlessOfResultOrder(existingID: Int?) async throws {
        let expected = lookup(mbid, existingID: existingID)
        let client = LookupClient(results: [lookup(otherMBID), expected])
        guard case .add(let artist) = try await LidarrArtistResolver.resolve(mbid: " \(mbid.uppercased())\n", using: client) else {
            Issue.record("Expected add confirmation")
            return
        }
        #expect(artist.foreignArtistId == mbid)
        #expect(!artist.isAlreadyAdded)
        #expect(await client.queries == ["lidarr:\(mbid)"])
        #expect(await client.artistIDs.isEmpty)
    }

    @Test func neverPresentsAnUnrelatedOrAmbiguousResultForAddition() async throws {
        for results in [[], [lookup(otherMBID)], [lookup(mbid), lookup(mbid)]] {
            let client = LookupClient(results: results)
            guard case .notFound = try await LidarrArtistResolver.resolve(mbid: mbid, using: client) else {
                Issue.record("Only one exact MBID match may be added")
                continue
            }
            #expect(await client.artistIDs.isEmpty)
        }
    }

    @Test func existingArtistIsLoadedForOpeningInsteadOfAdding() async throws {
        let client = LookupClient(results: [lookup(mbid, existingID: 42)], existing: artist(mbid))
        guard case .existing(let result) = try await LidarrArtistResolver.resolve(mbid: mbid, using: client) else {
            Issue.record("Expected existing artist")
            return
        }
        #expect(result.id == 42)
        #expect(result.foreignArtistId == mbid)
        #expect(await client.artistIDs == [42])
    }

    @Test func existingArtistMustStillMatchTheRequestedIdentifier() async throws {
        let client = LookupClient(results: [lookup(mbid, existingID: 42)], existing: artist(otherMBID))
        guard case .notFound = try await LidarrArtistResolver.resolve(mbid: mbid, using: client) else {
            Issue.record("Must reject an existing artist with a different MBID")
            return
        }
    }

    @Test func lateResultFromCancelledLookupIsDiscarded() async throws {
        let client = SuspendedLookupClient(result: lookup(mbid))
        let task = Task { try await LidarrArtistResolver.resolve(mbid: mbid, using: client) }
        await client.waitUntilStarted()
        task.cancel()
        await client.finish()
        do {
            _ = try await task.value
            Issue.record("Cancelled lookup must not open an add form")
        } catch is CancellationError {}
    }

    @Test func serverFailuresAreNotReportedAsMissingArtists() async throws {
        let client = LookupClient(results: [], failure: .unauthorized)
        do {
            _ = try await LidarrArtistResolver.resolve(mbid: mbid, using: client)
            Issue.record("Expected authentication failure")
        } catch let error as LidarrError {
            #expect(error == .unauthorized)
        }
    }

    private func lookup(_ id: String, existingID: Int? = nil) -> LidarrArtistLookup {
        LidarrArtistLookup(foreignArtistId: id, artistName: "Fixture artist", disambiguation: nil,
                           overview: nil, existingId: existingID, remotePoster: nil, images: nil)
    }

    private func artist(_ id: String) -> LidarrArtist {
        LidarrArtist(id: 42, artistName: "Fixture artist", foreignArtistId: id, overview: nil,
                     monitored: true, images: nil, statistics: nil)
    }
}

private actor LookupClient: LidarrArtistResolving {
    let results: [LidarrArtistLookup]
    let existing: LidarrArtist?
    let failure: LidarrError?
    private(set) var queries: [String] = []
    private(set) var artistIDs: [Int] = []

    init(results: [LidarrArtistLookup], existing: LidarrArtist? = nil, failure: LidarrError? = nil) {
        self.results = results
        self.existing = existing
        self.failure = failure
    }

    func searchArtists(term: String) async throws -> [LidarrArtistLookup] {
        queries.append(term)
        if let failure { throw failure }
        return results
    }

    func artist(id: Int) async throws -> LidarrArtist {
        artistIDs.append(id)
        return try #require(existing)
    }
}

private actor SuspendedLookupClient: LidarrArtistResolving {
    let result: LidarrArtistLookup
    private var continuation: CheckedContinuation<[LidarrArtistLookup], Never>?
    private var started: CheckedContinuation<Void, Never>?

    init(result: LidarrArtistLookup) { self.result = result }

    func searchArtists(term: String) async throws -> [LidarrArtistLookup] {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started?.resume()
            started = nil
        }
    }

    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func finish() {
        continuation?.resume(returning: [result])
        continuation = nil
    }

    func artist(id: Int) async throws -> LidarrArtist {
        throw LidarrError.badURL
    }
}
