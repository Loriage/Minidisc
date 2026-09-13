import SwiftUI
import SwiftData

/// Virtual starred-track playlist; server playlist editing actions do not apply.
struct ArtistBestOfView: View {
    let artistId: String
    let artistName: String
    let coverArtId: String?

    @Environment(\.appContainer) private var container
    @Environment(DominantColorExtractor.self) private var colorExtractor
    @Environment(\.colorScheme) private var colorScheme
    @State private var viewModel: ArtistBestOfViewModel?
    @State private var dominantColor: Color = .clear
    @Query(filter: #Predicate<FavoriteRecord> { $0.itemType == "song" })
    private var songFavorites: [FavoriteRecord]
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

    private var effectiveCoverArtId: String { coverArtId ?? artistId }

    private var songs: [DisplayableSong] {
        ArtistBestOf.filteredByLocalStars(
            viewModel?.songs ?? [],
            starredSongIds: Set(songFavorites.map(\.itemId))
        )
    }

    var body: some View {
        Group {
            if let vm = viewModel, !vm.isLoading, songs.isEmpty {
                if let error = vm.error {
                    EmptyStateView(
                        systemImage: "exclamationmark.triangle",
                        title: "Unable to Load Favorites",
                        subtitle: LocalizedStringKey(error.displayMessage),
                        action: .init(label: "Retry") { Task { await vm.load() } }
                    )
                } else {
                    EmptyStateView(
                        systemImage: "star",
                        title: "No Liked Songs",
                        subtitle: "Songs you favorite from this artist will appear here."
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
                viewModel = ArtistBestOfViewModel(
                    artistId: artistId,
                    artistName: artistName,
                    libraryService: c.libraryService,
                    downloadService: c.downloadService,
                    serverState: c.serverState
                )
            }
            await viewModel?.load()
        }
        .task(id: effectiveCoverArtId) {
            let cached = colorExtractor.bottomStripColor(for: effectiveCoverArtId, image: nil)
            if cached != .clear {
                dominantColor = cached
            } else if let image = await container?.artworkImageCache.load(coverArtId: effectiveCoverArtId) {
                let color = colorExtractor.bottomStripColor(for: effectiveCoverArtId, image: image)
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
        .refreshable { await viewModel?.load() }
        .environment(\.colorScheme, theme.isThemed ? (theme.isLight ? .light : .dark) : colorScheme)
    }

    private var heroContent: some View {
        VStack(spacing: MinidiscSpacing.s) {
            Text("The best of \(artistName)")
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

            HStack(spacing: MinidiscSpacing.l) {
                Button {
                    let shuffled = songs.shuffled()
                    Task { await container?.toastService.perform { try await container?.playerService.play(tracks: shuffled, startIndex: 0) } }
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

    private var allDownloaded: Bool {
        guard !songs.isEmpty, let serverId = container?.serverState.activeServer?.id else { return false }
        let onDisk = Set(downloadedTracks.filter { $0.serverId == serverId }.map(\.songId))
        return songs.allSatisfy { onDisk.contains($0.id) }
    }

    private func play(from index: Int) {
        let tracks = songs
        guard tracks.indices.contains(index) else { return }
        Task { await container?.toastService.perform { try await container?.playerService.play(tracks: tracks, startIndex: index) } }
    }
}
