import SwiftUI

struct LocalMusicCollectionView: View {
    let group: LocalMusicGroup
    let category: LocalMusicCategory
    @Environment(\.appContainer) private var container
    @Environment(\.colorScheme) private var colorScheme
    @Environment(ArtworkImageCache.self) private var artworkCache
    @Environment(DominantColorExtractor.self) private var colorExtractor
    @State private var coverImage: PlatformImage?
    @State private var dominantColor: Color = .clear

    private var tracks: [LocalMusicTrack] {
        (container?.localMusic.snapshot.tracks ?? []).filter {
            LocalMusicGroup.key(for: $0, category: category) == group.id
        }.sorted {
            let left = ($0.song.albumName ?? "", $0.song.discNumber ?? 1, $0.song.trackNumber ?? Int.max, $0.song.title)
            let right = ($1.song.albumName ?? "", $1.song.discNumber ?? 1, $1.song.trackNumber ?? Int.max, $1.song.title)
            return left < right
        }
    }

    private var artworkID: String { tracks.first?.song.coverArtId ?? tracks.first?.id ?? group.artworkID }
    private var palette: AlbumDetailPalette { AlbumDetailPalette(dominantColor: dominantColor, appearance: colorScheme) }

    var body: some View {
        ScrollView {
            VStack(spacing: MinidiscSpacing.xl) {
                if category == .albums {
                    AlbumArtworkSection(coverArtId: artworkID, coverImage: coverImage, albumName: group.name)
                    AlbumMetadataSection(albumName: group.name, artistName: tracks.first?.song.artist,
                                         artistId: nil, year: nil, genre: nil, isLoading: false, isOffline: true)
                } else {
                    LocalMusicArtwork(id: artworkID, isArtist: true)
                        .frame(width: 200, height: 200)
                    Text(group.name)
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, MinidiscSpacing.l)
                }

                LocalMusicPlaybackControls(tracks: tracks, foregroundColor: palette.contentColor)
                    .padding(.horizontal, MinidiscSpacing.l)

                if category == .artists {
                    VStack(alignment: .leading, spacing: MinidiscSpacing.m) {
                        Text("Albums").font(.minidiscShelfTitle)
                        LocalMusicGrid(groups: LocalMusicGroup.groups(in: tracks, category: .albums), category: .albums)
                    }
                    .padding(.horizontal, MinidiscSpacing.l)
                }

                LazyVStack(alignment: .leading, spacing: 0) {
                    if category == .artists {
                        Text("Songs").font(.minidiscShelfTitle)
                            .padding(.bottom, MinidiscSpacing.m)
                    }
                    LocalMusicTrackRows(tracks: tracks, showCoverArt: category == .artists,
                                        titleColor: palette.contentColor, secondaryColor: palette.secondaryContentColor,
                                        showsDividers: true)
                }
                .padding(.horizontal, MinidiscSpacing.l)
                .minidiscSongSwipeContainer()
            }
            .padding(.top, MinidiscSpacing.l)
            .padding(.bottom, MinidiscSpacing.xxl)
            .frame(maxWidth: .infinity)
        }
        .miniPlayerBottomMargin()
        .minidiscHideTopScrollEdgeEffect()
        .minidiscContentWidth()
        .environment(\.minidiscPlayingAccent, palette.contentColor)
        .environment(\.colorScheme, palette.preferredContentScheme ?? colorScheme)
        .background(AlbumDetailPageBackground(palette: palette))
        .foregroundStyle(palette.contentColor)
        .tint(palette.contentColor)
        .toolbarTitleDisplayMode(.inline)
        .toolbarColorScheme(palette.preferredContentScheme, for: .navigationBar)
        .refreshable { await container?.localMusic.refresh() }
        .task(id: artworkID) {
            let id = artworkID
            let image = await artworkCache.load(coverArtId: id, tier: .hero)
            guard !Task.isCancelled else { return }
            coverImage = image
            dominantColor = colorExtractor.dominantColor(for: id, image: image)
        }
    }
}

struct LocalMusicPlaybackControls: View {
    let tracks: [LocalMusicTrack]
    var foregroundColor: Color = .minidiscAccent
    @Environment(\.appContainer) private var container
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: MinidiscSpacing.m))
            : AnyLayout(HStackLayout(spacing: MinidiscSpacing.m))
        layout {
            Button { play(shuffled: false) } label: {
                Label("Play", systemImage: "play.fill")
                    .frame(maxWidth: .infinity).padding(.vertical, MinidiscSpacing.s)
            }
            Button { play(shuffled: true) } label: {
                Label("Shuffle", systemImage: "shuffle")
                    .frame(maxWidth: .infinity).padding(.vertical, MinidiscSpacing.s)
            }
        }
        .buttonStyle(.bordered)
        .tint(foregroundColor)
        .disabled(!tracks.contains(where: \.isAvailable))
    }

    private func play(shuffled: Bool) {
        let songs = tracks.filter(\.isAvailable).map(\.song)
        guard !songs.isEmpty else { return }
        HapticFeedback.medium.trigger()
        Task {
            await container?.toastService.perform {
                try await container?.playerService.play(tracks: shuffled ? songs.shuffled() : songs, startIndex: 0)
            }
        }
    }
}

struct LocalMusicTrackRows: View {
    let tracks: [LocalMusicTrack]
    var showCoverArt = true
    var titleColor: Color = .primary
    var secondaryColor: Color = .secondary
    var showsDividers = false
    @Environment(\.appContainer) private var container

    var body: some View {
        ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
            SongRow(song: track.song, index: index + 1, showCoverArt: showCoverArt,
                    showArtist: showCoverArt,
                    secondaryText: track.isAvailable ? nil : String(localized: "Unavailable on this device", table: "LocalMusic"),
                    titleColor: track.isAvailable ? titleColor : secondaryColor,
                    secondaryColor: secondaryColor, trailingAccessory: .menu,
                    onTap: { play(track) })
                .padding(.vertical, MinidiscSpacing.s)
                .id(track.id)
            if showsDividers && index < tracks.count - 1 {
                Divider().overlay(secondaryColor.opacity(0.12))
                    .padding(.leading, showCoverArt ? 52 : 36)
            }
        }
    }

    private func play(_ track: LocalMusicTrack) {
        let queue = tracks.filter { $0.isAvailable || $0.id == track.id }.map(\.song)
        guard let index = queue.firstIndex(where: { $0.id == track.id }) else { return }
        Task {
            await container?.toastService.perform {
                try await container?.playerService.play(tracks: queue, startIndex: index)
            }
        }
    }
}
