import SwiftUI
import SwiftData

/// "Recently Added" — the tracks of the library's newest albums, presented as a playlist.
///
/// The same lighter surface as `ArtistBestOfView`: no server playlist sits behind it, so editing, reordering,
/// renaming, deleting and playlist download have nothing to act on and are absent rather than disabled. It
/// borrows the playlist hero and track rows so it still reads as a playlist.
struct RecentlyAddedView: View {
    /// Cover of the newest album, passed by the row the user came from so the hero has artwork before the
    /// track fetch resolves. Falls back to the first fetched track's cover.
    let coverArtId: String?

    @Environment(\.appContainer) private var container
    @Environment(DominantColorExtractor.self) private var colorExtractor
    @Environment(\.colorScheme) private var colorScheme
    @State private var viewModel: RecentlyAddedViewModel?
    @State private var dominantColor: Color = .clear
    /// Unfiltered — the active server isn't known at init, so it's applied at read time (as PlaylistDetailView does).
    @Query private var downloadedTracks: [DownloadedTrack]

    private let heroHeight: CGFloat = 420

    private var theme: PlaylistTheme { PlaylistTheme(dominantColor: dominantColor) }
    private var headerTextColor: Color { theme.contentColor }
    private var headerSecondaryColor: Color { theme.secondaryContentColor }
    private var bodyColor: Color {
        if theme.isThemed { return theme.dominantColor }
        return Color(UIColor.systemBackground)
    }

    private var effectiveCoverArtId: String? { coverArtId ?? viewModel?.coverArtId }

    private var songs: [DisplayableSong] { viewModel?.songs ?? [] }

    var body: some View {
        Group {
            if let vm = viewModel, !vm.isLoading, songs.isEmpty {
                if let error = vm.error {
                    EmptyStateView(
                        systemImage: "exclamationmark.triangle",
                        title: "Unable to Load",
                        subtitle: LocalizedStringKey(error.displayMessage),
                        action: .init(label: "Retry") { Task { await vm.load() } }
                    )
                } else {
                    EmptyStateView(
                        systemImage: "music.note",
                        title: "No music yet",
                        subtitle: "Add some music to your server to get started"
                    )
                }
            } else {
                trackList
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayModeInline()
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(theme.isThemed ? (theme.isLight ? .light : .dark) : nil, for: .navigationBar)
        .task {
            guard let c = container else { return }
            if viewModel == nil {
                viewModel = RecentlyAddedViewModel(
                    libraryService: c.libraryService,
                    downloadService: c.downloadService,
                    serverState: c.serverState
                )
            }
            await viewModel?.load()
        }
        .task(id: effectiveCoverArtId) {
            guard let id = effectiveCoverArtId else { return }
            let cached = colorExtractor.bottomStripColor(for: id, image: nil)
            if cached != .clear {
                dominantColor = cached
            } else if let image = await container?.artworkImageCache.load(coverArtId: id) {
                let color = colorExtractor.bottomStripColor(for: id, image: image)
                withAnimation(.easeIn(duration: 0.2)) { dominantColor = color }
            }
        }
    }

    private var trackList: some View {
        List {
            ImmersiveCoverHero(
                coverArtId: effectiveCoverArtId,
                coverImage: nil,
                theme: theme,
                heroHeight: heroHeight
            ) {
                heroContent
            }
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            if let serverId = container?.serverState.activeServer?.id {
                PlaylistSongRows(
                    songs: songs,
                    serverId: serverId,
                    downloadingIds: viewModel?.downloadingIds ?? [],
                    titleColor: headerTextColor,
                    secondaryColor: headerSecondaryColor,
                    onTap: { index in play(from: index) },
                    onDownload: { id in Task { await viewModel?.download(songIds: [id]) } },
                    onRemoveDownload: { id in Task { await viewModel?.removeDownload(songId: id) } },
                    rowBackground: bodyColor
                )
            }
        }
        .listStyle(.plain)
        .ignoresSafeArea(.container, edges: .top)
        .minidiscHideTopScrollEdgeEffect()
        .background(bodyColor.ignoresSafeArea())
        .refreshable {
            if container?.serverState.isOnline == true {
                _ = try? await container?.libraryCatalog.refreshAlbums()
            }
            await viewModel?.load()
        }
        .environment(\.colorScheme, theme.isThemed ? (theme.isLight ? .light : .dark) : colorScheme)
    }

    private var heroContent: some View {
        VStack(spacing: MinidiscSpacing.s) {
            Text("Recently Added")
                .font(.system(.title, design: .rounded, weight: .semibold))
                .foregroundStyle(headerTextColor)
                .multilineTextAlignment(.center)
                .padding(.horizontal, MinidiscSpacing.l)
            // Held back until the fetch resolves — the hero renders before it, and "0 songs" flashing
            // under the title reads like an empty playlist.
            if viewModel?.isLoading == false {
                Text("\(songs.count) songs")
                    .font(.minidiscCaption)
                    .foregroundStyle(headerSecondaryColor)
                    .padding(.bottom, MinidiscSpacing.xs)
            }

            // Shuffle and download flank the Play disc so it stays centred, mirroring the artist hero.
            HStack(spacing: MinidiscSpacing.l) {
                Button {
                    let shuffled = songs.shuffled()
                    Task { try? await container?.playerService.play(tracks: shuffled, startIndex: 0) }
                } label: {
                    Image(systemName: "shuffle")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(headerTextColor)
                        .frame(width: 42, height: 42)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(songs.isEmpty)
                .accessibilityLabel("Shuffle")

                Button {
                    play(from: 0)
                } label: {
                    Circle()
                        .fill(.white)
                        .frame(width: 66, height: 66)
                        .overlay {
                            // Glyph knocked out of the white disc, matching the artist hero's transport.
                            Image(systemName: "play.fill")
                                .font(.system(size: 26, weight: .bold))
                                .blendMode(.destinationOut)
                        }
                        .compositingGroup()
                }
                .buttonStyle(.plain)
                .disabled(songs.isEmpty)
                .accessibilityLabel("Play")

                downloadButton
            }
        }
    }

    /// Downloads every track of the list individually (no playlist record — see the view model). Turns into
    /// a check once they're all on disk; per-track removal stays available from each row's context menu.
    private var downloadButton: some View {
        Button {
            let ids = songs.map(\.id)
            Task { await viewModel?.downloadAll(songIds: ids) }
        } label: {
            Group {
                if viewModel?.isDownloadingAll == true {
                    ProgressView().controlSize(.small).tint(headerTextColor)
                } else {
                    Image(systemName: allDownloaded ? "checkmark.circle.fill" : "arrow.down.circle")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(headerTextColor)
                }
            }
            .frame(width: 42, height: 42)
            .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(songs.isEmpty || allDownloaded || viewModel?.isDownloadingAll == true)
        .accessibilityLabel("Download")
    }

    /// Every visible track already on disk for the active server.
    private var allDownloaded: Bool {
        guard !songs.isEmpty, let serverId = container?.serverState.activeServer?.id else { return false }
        let onDisk = Set(downloadedTracks.filter { $0.serverId == serverId }.map(\.songId))
        return songs.allSatisfy { onDisk.contains($0.id) }
    }

    private func play(from index: Int) {
        let tracks = songs
        guard tracks.indices.contains(index) else { return }
        Task { try? await container?.playerService.play(tracks: tracks, startIndex: index) }
    }
}
