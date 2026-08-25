import SwiftUI
import SwiftSonic

struct WrappedTopArtistsSection: View {
    private static let maxConcurrentArtworkLoads = 4

    let artists: [TopArtistEntry]

    @Environment(\.appContainer) private var container
    @Environment(ArtworkImageCache.self) private var artworkImageCache
    @Environment(DominantColorExtractor.self) private var dominantColorExtractor
    @State private var artistToNavigate: ArtistID3?
    @State private var dominantColors: [String: Color] = [:]
    @State private var coverImages: [String: PlatformImage] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: MinidiscSpacing.s) {
            Text("Top Artists")
                .font(.minidiscSectionTitle)
            if artists.isEmpty {
                emptyLabel("No artist data for this period.")
            } else {
                carouselView
            }
        }
        .navigationDestination(item: $artistToNavigate) { ArtistDetailView(artist: $0) }
        .task(id: artists.map(\.artistId)) { await preloadColors() }
    }

    @ViewBuilder
    private var carouselView: some View {
        let allArtists = Array(artists.prefix(10))
        if !allArtists.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: MinidiscSpacing.m) {
                    ForEach(allArtists.indices, id: \.self) { index in
                        artistCard(allArtists[index], isFirst: index == 0)
                    }
                }
                .padding(.horizontal, MinidiscSpacing.l)
            }
            .padding(.horizontal, -MinidiscSpacing.l)
        }
    }

    private func artistCard(_ artist: TopArtistEntry, isFirst: Bool) -> some View {
        let cardWidth: CGFloat = isFirst ? 240 : 200
        return Button {
            Task {
                artistToNavigate = try? await container?.libraryService.artist(id: artist.artistId)
            }
        } label: {
            VStack(alignment: .leading, spacing: MinidiscSpacing.xs) {
                ZStack(alignment: .topLeading) {
                    CoverArtCard(
                        id: artist.artistId,
                        size: cardWidth,
                        tier: .hero,
                        cornerRadius: MinidiscCornerRadius.large,
                        initialImage: coverImages[artist.artistId]
                    )
                    dominantColors[artist.artistId, default: .clear]
                        .opacity(0.15)
                        .frame(width: cardWidth, height: cardWidth)
                        .clipShape(RoundedRectangle(cornerRadius: MinidiscCornerRadius.large, style: .continuous))
                    rankBadge(artist.rank)
                        .padding(MinidiscSpacing.xs)
                }
                CoverCardMetadata(
                    title: artist.name,
                    subtitle: artist.totalSecondsListened.wrappedCompactLabel()
                )
            }
            .frame(width: cardWidth)
        }
        .buttonStyle(.plain)
    }

    private func medalColor(for rank: Int) -> Color {
        switch rank {
        case 1: return WrappedYearPalette.medalGold
        case 2: return WrappedYearPalette.medalSilver
        case 3: return WrappedYearPalette.medalBronze
        default: return MinidiscColors.accent
        }
    }

    private func rankBadge(_ rank: Int) -> some View {
        let isMedal = rank <= 3
        return Text("#\(rank)")
            .font(.minidiscCaption2)
            .fontWeight(.bold)
            .foregroundStyle(isMedal ? Color.black : Color.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background {
                if isMedal {
                    Capsule().fill(medalColor(for: rank))
                } else {
                    Capsule().fill(.ultraThinMaterial)
                }
            }
    }

    private func emptyLabel(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.minidiscCaption)
            .foregroundStyle(.secondary)
    }

    @MainActor
    private func preloadColors() async {
        let topArtists = Array(artists.prefix(10))
        let expectedArtistIds = topArtists.map(\.artistId)
        var colors: [String: Color] = [:]
        var images: [String: PlatformImage] = [:]

        for artist in topArtists {
            if let cachedColor = dominantColorExtractor.cachedColor(for: artist.artistId) {
                colors[artist.artistId] = cachedColor
            }
        }

        await withTaskGroup(of: WrappedArtistArtworkResult.self) { group in
            var iterator = topArtists.makeIterator()

            for _ in 0..<min(Self.maxConcurrentArtworkLoads, topArtists.count) {
                guard let artist = iterator.next() else { break }
                let artistId = artist.artistId
                group.addTask { [artworkImageCache] in
                    await Self.loadArtworkResult(
                        artistId: artistId,
                        artworkImageCache: artworkImageCache
                    )
                }
            }

            while let result = await group.next() {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    continue
                }

                // Re-check the cache on MainActor so an override applied while the
                // image was loading always wins over the extracted average color.
                colors[result.artistId] =
                    dominantColorExtractor.cachedColor(for: result.artistId)
                    ?? dominantColorExtractor.storeColor(
                        packed: result.packedColor,
                        for: result.artistId
                    )

                if let artist = iterator.next() {
                    let artistId = artist.artistId
                    group.addTask { [artworkImageCache] in
                        await Self.loadArtworkResult(
                            artistId: artistId,
                            artworkImageCache: artworkImageCache
                        )
                    }
                }
            }
        }

        guard !Task.isCancelled,
              expectedArtistIds == Array(artists.prefix(10)).map(\.artistId)
        else { return }

        for artist in topArtists {
            if let image = artworkImageCache.cached(for: artist.artistId) {
                images[artist.artistId] = image
            }
        }
        dominantColors = colors
        coverImages = images
    }

    private nonisolated static func loadArtworkResult(
        artistId: String,
        artworkImageCache: ArtworkImageCache
    ) async -> WrappedArtistArtworkResult {
        guard !Task.isCancelled else {
            return WrappedArtistArtworkResult(artistId: artistId, packedColor: nil)
        }

        let image = await artworkImageCache.load(coverArtId: artistId)
        let packedColor = image.flatMap(DominantColorExtractor.packedAverageColor(from:))
        return WrappedArtistArtworkResult(artistId: artistId, packedColor: packedColor)
    }
}

private nonisolated struct WrappedArtistArtworkResult: Sendable {
    let artistId: String
    let packedColor: Int?
}
