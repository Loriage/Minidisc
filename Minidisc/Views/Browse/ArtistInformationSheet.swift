import SwiftUI
import SwiftSonic

/// Artist facts that Navidrome can substantiate. Origin and formation year are deliberately omitted because
/// neither Subsonic nor OpenSubsonic exposes them reliably.
struct ArtistInformationSheet: View {
    let artist: ArtistID3
    let biography: String?
    let lastFmURL: URL?
    let isLoadingBiography: Bool
    let dominantColor: Color

    @Environment(\.dismiss) private var dismiss

    private var albums: [AlbumID3] { artist.album ?? [] }

    private var albumCount: Int? {
        if !albums.isEmpty { return albums.count }
        return artist.albumCount
    }

    private var songCount: Int? {
        let count = albums.reduce(0) { $0 + $1.songCount }
        return count > 0 ? count : nil
    }

    private var firstReleaseYear: Int? {
        releaseYears.min()
    }

    private var latestReleaseYear: Int? {
        releaseYears.max()
    }

    private var releaseYears: [Int] {
        albums.compactMap { album in
            album.originalReleaseDate?.year ?? album.releaseDate?.year ?? album.year
        }
    }

    private var genres: [String] {
        var seen = Set<String>()
        let names = albums.flatMap { album -> [String] in
            var values = album.genres?.map(\.name) ?? []
            if let legacyGenre = album.genre {
                values.append(
                    contentsOf: legacyGenre
                        .split(whereSeparator: { $0 == ";" || $0 == "," })
                        .map(String.init)
                )
            }
            return values
        }

        return names.compactMap { name in
            let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, seen.insert(value.lowercased()).inserted else { return nil }
            return value
        }
    }

    private var musicBrainzURL: URL? {
        guard let id = artist.musicBrainzId, !id.isEmpty else { return nil }
        return URL(string: "https://musicbrainz.org/artist/\(id)")
    }

    private var accentColor: Color {
        guard dominantColor != .clear else {
            return Color(red: 0.12, green: 0.13, blue: 0.15)
        }
        return dominantColor
            .vibranceBoosted(0.08)
            .adjusted(saturation: -0.08, brightness: -0.05)
    }

    private let contentColor = Color.white
    private let secondaryColor = Color.white.opacity(0.68)
    private let tertiaryColor = Color.white.opacity(0.44)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(artist.name)
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(contentColor)
                        .textSelection(.enabled)
                        .padding(.bottom, 28)

                    facts

                    if !genres.isEmpty {
                        genreSection
                            .padding(.top, 28)
                    }

                    biographySection
                        .padding(.top, MinidiscSpacing.xxxl)

                    if lastFmURL != nil || musicBrainzURL != nil {
                        externalLinks
                            .padding(.top, 28)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 36)
                .padding(.bottom, MinidiscSpacing.xxxxl)
            }
            .contentMargins(.horizontal, MinidiscSpacing.xxl, for: .scrollContent)
            .background { sheetBackground }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    closeButton
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .background { sheetBackground }
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(36)
        .presentationBackground(Color.black)
    }

    private var closeButton: some View {
        Button(role: .close) {
            dismiss()
        } label: {
            Label("Close", systemImage: "xmark")
                .labelStyle(.iconOnly)
        }
    }

    private var facts: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), alignment: .leading),
                GridItem(.flexible(), alignment: .leading)
            ],
            alignment: .leading,
            spacing: MinidiscSpacing.l
        ) {
            if let albumCount {
                fact(title: "Albums", value: albumCount.formatted())
            }
            if let songCount {
                fact(title: "Songs", value: songCount.formatted())
            }
            if let firstReleaseYear {
                fact(
                    title: "First release",
                    value: firstReleaseYear.formatted(.number.grouping(.never))
                )
            }
            if let latestReleaseYear, latestReleaseYear != firstReleaseYear {
                fact(
                    title: "Latest Release",
                    value: latestReleaseYear.formatted(.number.grouping(.never))
                )
            }
        }
    }

    private func fact(title: LocalizedStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: MinidiscSpacing.xs) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(tertiaryColor)
            Text(value)
                .font(.title3.weight(.regular))
                .foregroundStyle(contentColor)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var genreSection: some View {
        VStack(alignment: .leading, spacing: MinidiscSpacing.s) {
            Text("Genre")
                .font(.footnote)
                .foregroundStyle(tertiaryColor)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: MinidiscSpacing.s) {
                    ForEach(genres, id: \.self) { genre in
                        Text(genre)
                            .font(.subheadline.weight(.regular))
                            .foregroundStyle(contentColor)
                            .padding(.horizontal, MinidiscSpacing.m)
                            .padding(.vertical, 5)
                            .background(contentColor.opacity(0.11), in: Capsule())
                    }
                }
            }
            .scrollClipDisabled()
        }
    }

    @ViewBuilder
    private var biographySection: some View {
        if isLoadingBiography {
            VStack(alignment: .leading, spacing: MinidiscSpacing.m) {
                Text("About")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(contentColor)
                ProgressView()
                    .tint(contentColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, MinidiscSpacing.xl)
            }
        } else if let biography = nonEmpty(biography) {
            VStack(alignment: .leading, spacing: MinidiscSpacing.m) {
                Text("About")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(contentColor)
                Text(biography)
                    .font(.body)
                    .foregroundStyle(secondaryColor)
                    .lineSpacing(5)
                    .textSelection(.enabled)
            }
        }
    }

    private var externalLinks: some View {
        VStack(alignment: .leading, spacing: MinidiscSpacing.m) {
            if let lastFmURL {
                externalLink(title: "Last.fm", destination: lastFmURL)
            }
            if let musicBrainzURL {
                externalLink(
                    title: "View on MusicBrainz",
                    destination: musicBrainzURL
                )
            }
        }
    }

    private func externalLink(
        title: LocalizedStringKey,
        destination: URL
    ) -> some View {
        Link(destination: destination) {
            HStack(spacing: MinidiscSpacing.s) {
                Image(systemName: "arrow.up.right")
                    .font(.subheadline.weight(.semibold))
                Text(title)
            }
            .font(.body.weight(.medium))
            .foregroundStyle(contentColor.opacity(0.9))
            .frame(minHeight: 32)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var sheetBackground: some View {
        ZStack {
            Color.black

            LinearGradient(
                stops: [
                    .init(
                        color: accentColor.adjusted(saturation: -0.04, brightness: -0.10),
                        location: 0
                    ),
                    .init(
                        color: accentColor.adjusted(saturation: -0.16, brightness: -0.25),
                        location: 0.56
                    ),
                    .init(color: Color.black.opacity(0.97), location: 1)
                ],
                startPoint: .topLeading,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
