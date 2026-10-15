import SwiftUI
import SwiftSonic

/// One discography group on an artist page ("Albums", "Live Albums", "Appears On"): a header that
/// collapses the list, Play and Shuffle for the whole group, and every album as a vertical row.
struct DiscographySection: View {
    let title: LocalizedStringResource
    let albums: [AlbumID3]
    @Binding var isExpanded: Bool
    /// Other artists' albums: rows name the album artist next to the year.
    var showsAlbumArtist = false
    var isPlayLoading = false
    let onPlay: () -> Void
    let onShuffle: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: MinidiscSpacing.s) {
            header
            if isExpanded {
                LazyVStack(spacing: 0) {
                    ForEach(albums) { album in
                        DiscographyAlbumRow(album: album, showsAlbumArtist: showsAlbumArtist)
                    }
                }
                .transition(.opacity)
            }
        }
    }

    private var header: some View {
        HStack(spacing: MinidiscSpacing.m) {
            Button {
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: MinidiscSpacing.s) {
                    Text(title)
                        .font(.minidiscShelfTitle)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Image(systemName: "chevron.down")
                        .font(.minidiscCaption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? Text("Expanded") : Text("Collapsed"))
            .accessibilityHint(Text("Shows or hides these albums"))
            .accessibilityAddTraits(.isHeader)

            Spacer(minLength: MinidiscSpacing.s)

            Button("Play", systemImage: "play.fill") { onPlay() }
                .buttonStyle(.minidiscCircle(diameter: MinidiscControlSize.compact, isProminent: true))
                .disabled(isPlayLoading || albums.isEmpty)
            Button("Shuffle", systemImage: "shuffle") { onShuffle() }
                .buttonStyle(.minidiscCircle(diameter: MinidiscControlSize.compact))
                .disabled(isPlayLoading || albums.isEmpty)
        }
        .padding(.horizontal, MinidiscSpacing.l)
    }
}

/// Cover, title, "year · N songs" and a chevron; opens the album.
struct DiscographyAlbumRow: View {
    let album: AlbumID3
    var showsAlbumArtist = false

    private static let artworkSize: CGFloat = 56

    private var subtitle: String {
        var parts: [String] = []
        if showsAlbumArtist, let artist = album.artist, !artist.isEmpty { parts.append(artist) }
        if let year = album.year { parts.append(String(year)) }
        if album.songCount > 0 { parts.append(String(localized: "\(album.songCount) songs")) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        NavigationLink(value: HomeDestination.album(album)) {
            HStack(spacing: MinidiscSpacing.m) {
                CoverArtCard(id: album.coverArt ?? album.id, size: Self.artworkSize)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: album.name)
                        .font(.minidiscTrackTitle)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    if !subtitle.isEmpty {
                        Text(verbatim: subtitle)
                            .font(.minidiscMetadata)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: MinidiscSpacing.s)
                Image(systemName: "chevron.right")
                    .font(.minidiscCaption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, MinidiscSpacing.l)
            .padding(.vertical, MinidiscSpacing.s)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("discography.album.\(album.id)")
    }
}

#if DEBUG
#Preview {
    @Previewable @State var albumsExpanded = true
    @Previewable @State var singlesExpanded = false
    MinidiscPreview(container: .preview()) {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: MinidiscSpacing.section) {
                    DiscographySection(
                        title: "Albums",
                        albums: [PreviewFixtures.tidalRooms, PreviewFixtures.paperLanterns].map(PreviewFixtures.withoutSongs),
                        isExpanded: $albumsExpanded,
                        onPlay: {},
                        onShuffle: {}
                    )
                    DiscographySection(
                        title: "Singles",
                        albums: [PreviewFixtures.withoutSongs(PreviewFixtures.glasshouse)],
                        isExpanded: $singlesExpanded,
                        onPlay: {},
                        onShuffle: {}
                    )
                    DiscographySection(
                        title: "Appears On",
                        albums: [PreviewFixtures.withoutSongs(PreviewFixtures.midnightTransit)],
                        isExpanded: .constant(true),
                        showsAlbumArtist: true,
                        onPlay: {},
                        onShuffle: {}
                    )
                }
                .padding(.vertical, MinidiscSpacing.l)
            }
            .background(ArtworkSurfaceBackground(tint: ArtworkSurfacePalette.tint(from: .teal)))
        }
        .environment(\.colorScheme, .dark)
    }
}
#endif
