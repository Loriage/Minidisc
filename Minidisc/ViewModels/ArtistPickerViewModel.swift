import Foundation
import SwiftSonic
import OSLog

/// Resolves the artists credited on a track for the artist picker: their library record (for the photo)
/// and how many albums of theirs are in the collection, filed under them or crediting them.
@Observable
@MainActor
final class ArtistPickerViewModel {
    nonisolated struct Entry: Identifiable, Sendable {
        /// Position in the credit list; credits are not guaranteed to carry unique IDs.
        let id: Int
        let credit: ArtistCredit
        var artist: ArtistID3?
        /// Albums filed under the artist plus albums crediting them. `nil` until resolved.
        var albumCount: Int?

        var coverArtID: String? { artist?.coverArt }
        var isInLibrary: Bool { (albumCount ?? 0) > 0 }
    }

    private(set) var entries: [Entry]
    private(set) var isResolving = true

    private let library: any ArtistBrowsing & ArtistRecommendationBrowsing
    private static let maxConcurrentLookups = 5

    init(credits: [ArtistCredit], library: any ArtistBrowsing & ArtistRecommendationBrowsing) {
        self.entries = credits.enumerated().map { Entry(id: $0.offset, credit: $0.element) }
        self.library = library
    }

    var inLibrary: [Entry] { entries.filter(\.isInLibrary) }
    var notInLibrary: [Entry] { entries.filter { !$0.isInLibrary } }

    func resolve() async {
        isResolving = true
        defer { isResolving = false }
        let library = library
        await withTaskGroup(of: (Int, ArtistID3?, Int).self) { group in
            var pending = entries.makeIterator()
            func enqueue() {
                guard let entry = pending.next() else { return }
                group.addTask {
                    await Self.lookUp(entry.credit, index: entry.id, library: library)
                }
            }
            for _ in 0..<Self.maxConcurrentLookups { enqueue() }
            for await (index, artist, count) in group {
                guard !Task.isCancelled, entries.indices.contains(index) else { continue }
                entries[index].artist = artist
                entries[index].albumCount = count
                enqueue()
            }
        }
    }

    private nonisolated static func lookUp(
        _ credit: ArtistCredit,
        index: Int,
        library: any ArtistBrowsing & ArtistRecommendationBrowsing
    ) async -> (Int, ArtistID3?, Int) {
        var artist: ArtistID3?
        if let id = credit.id, !id.isEmpty {
            artist = try? await library.artist(id: id)
        }
        if artist == nil {
            artist = await library.findArtist(byName: credit.name)
        }
        guard let artist else { return (index, nil, 0) }
        let filed = artist.album?.count ?? artist.albumCount ?? 0
        do {
            let credited = try await library.appearances(artistID: artist.id, artistName: artist.name)
            let filedIDs = Set((artist.album ?? []).map(\.id))
            return (index, artist, filed + credited.albums.filter { !filedIDs.contains($0.id) }.count)
        } catch {
            Logger.library.debug("Artist picker: appearance count failed for \(artist.id, privacy: .public)")
            return (index, artist, filed)
        }
    }
}
