import SwiftUI
import SwiftSonic
import SwiftData
import OSLog

// MARK: - Mode

enum AlbumDetailMode: Sendable {
    case full           // show all album songs (default — online catalog browsing)
    case downloadedOnly // show only downloaded tracks (Downloads/Offline contexts for purely-partial albums)
}

private struct AlbumRecommendationRequest: Equatable {
    let albumId: String
    let artistId: String?
    let artistName: String?
}

struct AlbumDetailView: View {
    private let albumId: String
    private let initialName: String
    private let initialArtistId: String?
    private let initialArtistName: String?
    private let coverArtId: String?
    private let initialCoverImage: PlatformImage?
    private let zoomSourceId: String?
    private let zoomNamespace: Namespace.ID?
    private let mode: AlbumDetailMode

    init(album: AlbumID3, zoomSourceId: String? = nil, zoomNamespace: Namespace.ID? = nil, coverArtId: String? = nil, initialDominantColor: Color = .clear, initialCoverImage: PlatformImage? = nil, mode: AlbumDetailMode = .full) {
        albumId = album.id
        initialName = album.name
        initialArtistId = album.artistId
        initialArtistName = album.artist
        self.coverArtId = coverArtId
        self.initialCoverImage = initialCoverImage
        let cid = "album:\(album.id)"
        let aid = album.id
        _albumFavoriteMatches = Query(filter: #Predicate<FavoriteRecord> { $0.id == cid })
        _downloadedAlbumTracks = Query(filter: #Predicate<DownloadedTrack> { $0.albumId == aid })
        self.zoomSourceId = zoomSourceId
        self.zoomNamespace = zoomNamespace
        self.mode = mode
        _dominantColor = State(initialValue: initialDominantColor)
    }

    init(albumId: String, albumName: String, zoomSourceId: String? = nil, zoomNamespace: Namespace.ID? = nil, coverArtId: String? = nil, initialDominantColor: Color = .clear, initialCoverImage: PlatformImage? = nil, mode: AlbumDetailMode = .full) {
        self.albumId = albumId
        self.initialName = albumName
        initialArtistId = nil
        initialArtistName = nil
        self.coverArtId = coverArtId
        self.initialCoverImage = initialCoverImage
        let cid = "album:\(albumId)"
        let aid = albumId
        _albumFavoriteMatches = Query(filter: #Predicate<FavoriteRecord> { $0.id == cid })
        _downloadedAlbumTracks = Query(filter: #Predicate<DownloadedTrack> { $0.albumId == aid })
        self.zoomSourceId = zoomSourceId
        self.zoomNamespace = zoomNamespace
        self.mode = mode
        _dominantColor = State(initialValue: initialDominantColor)
    }

    @Environment(\.appContainer) private var container
    @Environment(PlaylistAddition.self) private var playlistAddition
    @Environment(\.dismiss) private var dismiss
    @Environment(DominantColorExtractor.self) private var colorExtractor
    @Environment(ArtworkImageCache.self) private var artworkImageCache
    @Environment(\.colorScheme) private var colorScheme
    @State private var viewModel: AlbumDetailViewModel?
    @State private var dominantColor: Color = .clear
    @State private var showDeleteAlert = false
    @State private var showThemeColorSheet = false
    @State private var recommendedAlbums: [AlbumID3] = []
    @Query private var albumFavoriteMatches: [FavoriteRecord]
    @Query private var downloadedAlbumTracks: [DownloadedTrack]

    private var isAlbumFavorite: Bool { !albumFavoriteMatches.isEmpty }
    private var isOnline: Bool { container?.serverState.isOnline == true }
    /// Cover id the album theme is keyed on — the colour override is stored under the same id so it takes effect.
    private var albumCoverId: String { viewModel?.coverArtId ?? coverArtId ?? albumId }
    /// Every cover id the override must cover so it's resolved from ANY surface: the album cover + each song's
    /// own cover id (these can differ from the album's while pointing at the same artwork — e.g. the full player).
    private var albumThemeIds: [String] {
        [albumCoverId] + (viewModel?.songs.compactMap { $0.coverArtId } ?? [])
    }
    /// Drops the manual override and falls back to the colour extracted from the cover.
    private func resetThemeColor() {
        colorExtractor.setColorOverride(nil, forIds: albumThemeIds)
        dominantColor = colorExtractor.cachedColor(for: albumCoverId) ?? dominantColor
    }
    private var isLoadingSkeleton: Bool {
        viewModel == nil || (viewModel?.isLoading == true && viewModel?.songs.isEmpty == true)
    }
    private var palette: AlbumDetailPalette {
        AlbumDetailPalette(dominantColor: dominantColor, appearance: colorScheme)
    }
    private var headerTextColor: Color { palette.contentColor }
    private var headerSecondaryColor: Color { palette.secondaryContentColor }

    private var recommendationRequest: AlbumRecommendationRequest? {
        guard case .full = mode,
              isOnline else {
            return nil
        }

        return AlbumRecommendationRequest(
            albumId: albumId,
            artistId: initialArtistId,
            artistName: initialArtistName
        )
    }

    private var visibleRecommendedAlbums: [AlbumID3] {
        let excludedArtistId = viewModel?.artistId ?? initialArtistId
        let excludedArtistName = (viewModel?.artistName ?? initialArtistName)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return Array(
            recommendedAlbums.lazy
                .filter { album in
                    if let excludedArtistId, album.artistId == excludedArtistId {
                        return false
                    }
                    if let excludedArtistName,
                       album.artist?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                           == excludedArtistName {
                        return false
                    }
                    return true
                }
                .prefix(AlbumYouMightAlsoLikeSection.resultLimit)
        )
    }

    private var effectiveInitialImage: PlatformImage? {
        initialCoverImage ?? artworkImageCache.cachedImage(for: coverArtId ?? albumId)
    }

    // MARK: - Song filtering

    private var offlineFallbackSongs: [DisplayableSong] {
        downloadedAlbumTracks
            .sorted { ($0.trackNumber ?? Int.max) < ($1.trackNumber ?? Int.max) }
            .map { DisplayableSong(from: $0) }
    }

    private func filteredSongs(_ vmSongs: [DisplayableSong]) -> [DisplayableSong] {
        switch mode {
        case .full:
            return vmSongs
        case .downloadedOnly:
            let downloadedIds = Set(downloadedAlbumTracks.map(\.songId))
            return vmSongs.filter { downloadedIds.contains($0.id) }
        }
    }

    private func displaySongs() -> [DisplayableSong] {
        switch mode {
        case .downloadedOnly:
            if let vm = viewModel, vm.error == nil, !vm.songs.isEmpty {
                return filteredSongs(vm.songs)
            }
            return offlineFallbackSongs
        case .full:
            // Prefer the VM's catalog list, but back-stop with downloaded tracks whenever
            // the VM produced nothing — whether it errored OR returned an empty-success
            // payload (captive proxy / Cloudflare-WARP). This is the view-level safety net
            // that keeps a downloaded album readable through normal nav, not just Downloads.
            if let vm = viewModel, !vm.songs.isEmpty {
                return vm.songs
            }
            return offlineFallbackSongs
        }
    }

    private func shouldShowTrackArtists(in songs: [DisplayableSong]) -> Bool {
        let trackArtists = Set(
            songs.compactMap { song -> String? in
                guard let artist = song.artist?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !artist.isEmpty else { return nil }
                return artist.lowercased()
            }
        )

        if trackArtists.count > 1 {
            return true
        }

        guard let trackArtist = trackArtists.first,
              let albumArtist = viewModel?.artistName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
              !albumArtist.isEmpty else {
            return false
        }

        return trackArtist != albumArtist
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                let songs = displaySongs()

                AlbumArtworkSection(
                    coverArtId: viewModel?.coverArtId ?? coverArtId ?? albumId,
                    coverImage: effectiveInitialImage,
                    albumName: viewModel?.albumName ?? initialName
                )
                .padding(.top, MinidiscSpacing.xxl)

                AlbumMetadataSection(
                    albumName: viewModel?.albumName ?? initialName,
                    artistName: viewModel?.artistName,
                    artistId: viewModel?.artistId,
                    year: viewModel?.year,
                    genre: viewModel?.genre,
                    isLoading: viewModel == nil,
                    isOffline: viewModel?.isOffline == true
                )
                .padding(.top, MinidiscSpacing.xl)

                AlbumPlaybackActions(
                    albumId: albumId,
                    songs: songs,
                    mode: mode,
                    viewModel: viewModel,
                    downloadedAlbumTracks: downloadedAlbumTracks,
                    contentColor: palette.contentColor,
                    controlFillColor: palette.controlFillColor,
                    playLabelColor: palette.playLabelColor,
                    showDeleteAlert: $showDeleteAlert
                )
                .padding(.top, MinidiscSpacing.l)
                .padding(.bottom, MinidiscSpacing.xl)

                if isLoadingSkeleton {
                    AlbumTrackSkeletonRows()
                } else if let vm = viewModel {
                    let serverId = container?.serverState.activeServer?.id ?? UUID()
                    if songs.isEmpty {
                        if mode == .downloadedOnly {
                            EmptyStateView(
                                systemImage: "arrow.down.circle.slash",
                                title: "No Downloaded Tracks",
                                subtitle: "No tracks from this album have been downloaded."
                            )
                        } else if let error = vm.error {
                            EmptyStateView(
                                systemImage: "exclamationmark.triangle",
                                title: "Unable to Load Album",
                                subtitle: LocalizedStringKey(error.displayMessage),
                                action: .init(label: "Retry") { Task { await vm.load() } }
                            )
                        } else {
                            EmptyStateView(
                                systemImage: "music.note",
                                title: "No Tracks",
                                subtitle: "This album doesn't have any tracks yet."
                            )
                        }
                    } else {
                        AlbumSongRows(
                            songs: songs,
                            albumId: albumId,
                            serverId: serverId,
                            showArtists: shouldShowTrackArtists(in: songs),
                            downloadingIds: vm.downloadingIds,
                            titleColor: headerTextColor,
                            secondaryColor: headerSecondaryColor,
                            onTap: { index in
                                Task {
                                    do {
                                        try await container?.playerService.play(tracks: songs, startIndex: index)
                                    } catch {
                                        Logger.player.error("[PLAYBACK] play failed: \(error, privacy: .public)")
                if !UserFacingError.isCancellation(error) {
                    container?.toastService.showError(UserFacingError.from(error).displayMessage)
                }
                                    }
                                }
                            },
                            onDownload: (mode == .downloadedOnly || vm.isOffline || vm.isDownloadingAlbum) ? nil : { songId in
                                Task { await vm.downloadSong(id: songId) }
                            },
                            onRemoveDownload: { songId in
                                Task { await container?.toastService.perform { try await container?.downloadService.remove(songId: songId, serverId: serverId) } }
                            },
                            onAddToPlaylist: playlistAddition.present
                        )

                        AlbumReleaseInformationSection(
                            releaseDate: vm.releaseDate,
                            fallbackYear: vm.year,
                            songCount: songs.count,
                            totalDuration: songs.reduce(0) { $0 + $1.duration },
                            releaseTypes: vm.releaseTypes,
                            version: vm.version,
                            recordLabels: vm.recordLabels,
                            audioFormats: songs.compactMap(\.audioFormat),
                            textColor: headerSecondaryColor
                        )

                        if case .full = mode, !vm.isOffline {
                            if let artistId = vm.artistId,
                               let artistName = vm.artistName,
                               !artistName.isEmpty {
                                AlbumMoreByArtistSection(
                                    artistId: artistId,
                                    artistName: artistName,
                                    currentAlbumId: albumId
                                )
                            }

                            AlbumYouMightAlsoLikeSection(albums: visibleRecommendedAlbums)
                        }
                    }
                }
            }
        }
        .refreshable { await viewModel?.load() }
        .miniPlayerBottomMargin()
        .minidiscHideTopScrollEdgeEffect()
        .alert("Remove downloaded album?", isPresented: $showDeleteAlert) {
            Button("Remove", role: .destructive) { Task { await viewModel?.deleteDownload() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The audio files will be deleted from this device.")
        }
        .background(AlbumDetailPageBackground(palette: palette))
        .minidiscContentWidth()
        .environment(\.minidiscPlayingAccent, palette.contentColor)
        .environment(\.colorScheme, palette.preferredContentScheme ?? colorScheme)
        .navigationTitle("")
        .navigationBarTitleDisplayModeInline()
        .navigationBarBackButtonHidden(true)
        .enableSwipeBack()
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Back", systemImage: "chevron.left") {
                    dismiss()
                }
                .tint(palette.contentColor)
            }
            ToolbarItem(placement: .primaryAction) {
                Button(
                    isAlbumFavorite ? "Remove from Favorites" : "Add to Favorites",
                    systemImage: isAlbumFavorite ? "star.fill" : "star"
                ) {
                    HapticFeedback.light.trigger()
                    Task {
                        if isAlbumFavorite {
                            await container?.toastService.perform { try await container?.favoritesService.unstar(itemType: .album, itemId: albumId) }
                        } else {
                            await container?.toastService.perform { try await container?.favoritesService.star(itemType: .album, itemId: albumId) }
                        }
                    }
                }
                .tint(palette.contentColor)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isAlbumFavorite)
                .disabled(!isOnline)
            }
            ToolbarItem(placement: .primaryAction) {
                Menu("More options", systemImage: "ellipsis") {
                    Group {
                        Button("Instant Mix", systemImage: instantMixSymbol) {
                            HapticFeedback.medium.trigger()
                            startInstantMix(from: .album(id: albumId), using: container)
                        }
                        .disabled(displaySongs().isEmpty || !isOnline)
                        Divider()
                        // A ColorPicker cannot live inside a Menu — menu content is limited to buttons and
                        // pickers — so the swatch moves to a sheet. Which is the better home anyway: "Reset to
                        // cover colour" used to hide in a contextMenu on a toolbar item, where nobody long-presses.
                        Button("Theme colour", systemImage: "paintpalette") {
                            showThemeColorSheet = true
                        }
                        if colorExtractor.colorOverride(for: albumCoverId) != nil {
                            Button("Reset to cover colour", systemImage: "arrow.uturn.backward") {
                                resetThemeColor()
                            }
                        }
                    }
                    .tint(palette.contentColor)
                }
                .tint(palette.contentColor)
            }
        }
        .sheet(isPresented: $showThemeColorSheet) {
            ThemeColorSheet(
                color: Binding(
                    get: { colorExtractor.cachedColor(for: albumCoverId) ?? dominantColor },
                    set: { newColor in
                        colorExtractor.setColorOverride(newColor, forIds: albumThemeIds)
                        dominantColor = newColor
                    }
                ),
                hasOverride: colorExtractor.colorOverride(for: albumCoverId) != nil,
                footerText: "Overrides the colour taken from the cover, here and anywhere else this album appears.",
                onReset: resetThemeColor
            )
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(palette.preferredContentScheme, for: .navigationBar)
        // Keyed on connectivity so the list re-loads from the right source when
        // NWPathMonitor flips isOnline — same pattern as AlbumDetailMacOS and
        // PlaylistDetailView.
        .task(id: container?.serverState.isOnline) {
            guard let c = container else { return }
            if viewModel == nil {
                viewModel = AlbumDetailViewModel(
                    albumId: albumId,
                    libraryService: c.libraryService,
                    downloadService: c.downloadService,
                    toastService: c.toastService,
                    serverState: c.serverState
                )
            }
            await viewModel?.load()
        }
        .task(id: viewModel?.coverArtId) {
            guard let artId = viewModel?.coverArtId else { return }

            let cached = colorExtractor.dominantColor(for: artId, image: nil)
            if cached != .clear {
                dominantColor = cached
                return
            }

            await loadDominantColor(coverArtId: artId)
        }
        .task(id: recommendationRequest) {
            guard let recommendationRequest else {
                recommendedAlbums = []
                return
            }

            await loadAlbumRecommendations(for: recommendationRequest)
        }
        .minidiscZoomTransition(sourceID: zoomSourceId, in: zoomNamespace)
    }

    // MARK: - Color loading

    private func loadDominantColor(coverArtId: String) async {
        guard let image = await container?.artworkImageCache.load(coverArtId: coverArtId) else { return }
        let color = colorExtractor.dominantColor(for: coverArtId, image: image)
        withAnimation(.easeIn(duration: 0.2)) {
            dominantColor = color
        }
    }

    private func loadAlbumRecommendations(for request: AlbumRecommendationRequest) async {
        guard let container else {
            recommendedAlbums = []
            return
        }

        do {
            let needsArtistFilteringAfterAlbumLoad = request.artistId == nil
                && request.artistName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
            let requestLimit = AlbumYouMightAlsoLikeSection.resultLimit
                + (needsArtistFilteringAfterAlbumLoad ? 2 : 0)
            let recommendations = try await container.libraryService.similarAlbums(
                to: request.albumId,
                excludingArtistID: request.artistId,
                excludingArtistName: request.artistName,
                limit: requestLimit
            )
            try Task.checkCancellation()
            recommendedAlbums = recommendations
        } catch is CancellationError {
            return
        } catch {
            recommendedAlbums = []
            Logger.library.warning(
                "Unable to load album recommendations for \(request.albumId, privacy: .public): \(error, privacy: .public)"
            )
        }
    }
}

// MARK: - Album presentation

private struct AlbumDetailPalette {
    let backgroundTopColor: Color
    let backgroundBottomColor: Color
    let contentColor: Color
    let secondaryContentColor: Color
    let controlFillColor: Color
    let playLabelColor: Color
    let preferredContentScheme: ColorScheme?

    init(dominantColor: Color, appearance: ColorScheme) {
        guard dominantColor != .clear else {
            let background = Color(UIColor.systemBackground)
            backgroundTopColor = background
            backgroundBottomColor = background
            contentColor = .primary
            secondaryContentColor = .secondary
            controlFillColor = Color.primary.opacity(0.12)
            playLabelColor = .black
            preferredContentScheme = nil
            return
        }

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        guard UIColor(dominantColor).getHue(
            &hue,
            saturation: &saturation,
            brightness: &brightness,
            alpha: &alpha
        ) else {
            let usesDarkContent = dominantColor.luminance > 0.6
            let foreground: Color = usesDarkContent ? .black : .white
            backgroundTopColor = dominantColor
            backgroundBottomColor = dominantColor
            contentColor = foreground
            secondaryContentColor = foreground.opacity(0.7)
            controlFillColor = foreground.opacity(0.12)
            playLabelColor = usesDarkContent ? .black : dominantColor
            preferredContentScheme = usesDarkContent ? .light : .dark
            return
        }

        let isChromatic = saturation >= 0.08
        let adjustedSaturation: Double
        let adjustedBrightness: Double

        if isChromatic {
            adjustedSaturation = min(
                max(Double(saturation) * (appearance == .dark ? 1.7 : 1.45), 0.46),
                0.96
            )
            adjustedBrightness = appearance == .dark
                ? min(max(Double(brightness) * 0.78, 0.28), 0.48)
                : min(max(Double(brightness) * 1.08, 0.52), 0.74)
        } else {
            // Neutral artwork still needs an artwork-led surface. Apple Music turns monochrome covers into a
            // mid-grey page in both appearances instead of falling back to pure system black or white.
            adjustedSaturation = min(Double(saturation) * 1.2, 0.10)
            adjustedBrightness = appearance == .dark
                ? min(max(Double(brightness) * 0.52, 0.18), 0.30)
                : min(max(Double(brightness) * 0.78, 0.34), 0.48)
        }

        func themedColor(brightnessMultiplier: Double) -> Color {
            Color(
                hue: Double(hue),
                saturation: adjustedSaturation,
                brightness: min(max(adjustedBrightness * brightnessMultiplier, 0), 1)
            )
        }

        let topColor = themedColor(brightnessMultiplier: appearance == .dark ? 1.06 : 1.08)
        let bottomColor = themedColor(brightnessMultiplier: appearance == .dark ? 0.84 : 0.92)
        let usesDarkContent = topColor.luminance > 0.62 && bottomColor.luminance > 0.55
        let foreground: Color = usesDarkContent ? .black : .white

        backgroundTopColor = topColor
        backgroundBottomColor = bottomColor
        contentColor = foreground
        secondaryContentColor = foreground.opacity(0.7)
        controlFillColor = foreground.opacity(0.12)
        playLabelColor = themedColor(
            brightnessMultiplier: min(max(0.32 / max(adjustedBrightness, 0.01), 0.5), 1)
        )
        preferredContentScheme = usesDarkContent ? .light : .dark
    }
}

private struct AlbumDetailPageBackground: View {
    let palette: AlbumDetailPalette

    var body: some View {
        LinearGradient(
            colors: [palette.backgroundTopColor, palette.backgroundBottomColor],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

private struct AlbumArtworkSection: View {
    let coverArtId: String
    let coverImage: PlatformImage?
    let albumName: String

    var body: some View {
        CoverArtView(
            id: coverArtId,
            size: 800,
            tier: .hero,
            cornerRadius: MinidiscCornerRadius.large,
            initialImage: coverImage
        )
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 340)
        .minidiscCoverStyle(cornerRadius: MinidiscCornerRadius.large)
        .shadow(color: .black.opacity(0.16), radius: 12, y: 6)
        .padding(.horizontal, 64)
        .accessibilityLabel(
            Text(
                "Artwork for \(albumName)",
                comment: "Accessibility label for the album cover; the variable is the album title."
            )
        )
    }
}

private struct AlbumMetadataSection: View {
    let albumName: String
    let artistName: String?
    let artistId: String?
    let year: Int?
    let genre: String?
    let isLoading: Bool
    let isOffline: Bool

    var body: some View {
        VStack(spacing: MinidiscSpacing.xs) {
            Text(albumName)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .lineLimit(2)

            if isLoading {
                SkeletonBlock(width: 140, height: 18, cornerRadius: 4)
            } else if let artistName {
                if let artistId, !isOffline {
                    NavigationLink(value: HomeDestination.artist(ArtistID3(id: artistId, name: artistName))) {
                        Text(artistName)
                            .font(.title3.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(artistName)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            if isLoading {
                SkeletonBlock(width: 100, height: 14, cornerRadius: 4)
                    .padding(.top, MinidiscSpacing.xs)
            } else {
                AlbumMetadataLine(genre: genre, year: year)
                    .padding(.top, MinidiscSpacing.xs)
            }
        }
        .padding(.horizontal, MinidiscSpacing.xxl)
    }
}

private struct AlbumMetadataLine: View {
    let genre: String?
    let year: Int?

    var body: some View {
        HStack(spacing: MinidiscSpacing.xs) {
            if let genre, !genre.isEmpty {
                Text(genre)
                    .lineLimit(1)
            }
            if genre?.isEmpty == false, year != nil {
                Text("·")
            }
            if let year {
                Text(String(year))
            }
        }
        .font(.minidiscCaption)
        .foregroundStyle(.secondary)
    }
}

private struct AlbumPlaybackActions: View {
    let albumId: String
    let songs: [DisplayableSong]
    let mode: AlbumDetailMode
    let viewModel: AlbumDetailViewModel?
    let downloadedAlbumTracks: [DownloadedTrack]
    let contentColor: Color
    let controlFillColor: Color
    let playLabelColor: Color
    @Binding var showDeleteAlert: Bool

    @Environment(\.appContainer) private var container

    var body: some View {
        VStack(spacing: MinidiscSpacing.m) {
            HStack(spacing: MinidiscSpacing.m) {
                Button {
                    HapticFeedback.medium.trigger()
                    Task {
                        guard !songs.isEmpty else { return }
                        await container?.toastService.perform { try await container?.playerService.play(tracks: songs.shuffled(), startIndex: 0) }
                    }
                } label: {
                    AlbumCircularActionLabel(
                        systemImage: "shuffle",
                        foregroundColor: contentColor,
                        backgroundColor: controlFillColor
                    )
                }
                .disabled(songs.isEmpty)
                .accessibilityLabel("Shuffle")

                PlayButton(
                    action: {
                        Task {
                            guard !songs.isEmpty else { return }
                            await container?.toastService.perform { try await container?.playerService.play(tracks: songs, startIndex: 0) }
                        }
                    },
                    isDisabled: songs.isEmpty,
                    accentColor: .white,
                    labelColor: playLabelColor,
                    height: 48
                )
                .frame(maxWidth: 220)

                AlbumDownloadActionButton(
                    albumId: albumId,
                    mode: mode,
                    viewModel: viewModel,
                    downloadedAlbumTracks: downloadedAlbumTracks,
                    contentColor: contentColor,
                    controlFillColor: controlFillColor,
                    showDeleteAlert: $showDeleteAlert
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, MinidiscSpacing.xxxxl)

            if mode == .full, let viewModel, viewModel.isDownloadingAlbum {
                AlbumDownloadProgress(
                    downloaded: downloadedAlbumTracks.count,
                    total: viewModel.songs.count
                )
            }
        }
    }
}

private struct AlbumCircularActionLabel: View {
    let systemImage: String
    let foregroundColor: Color
    let backgroundColor: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(.minidiscCellTitle)
            .foregroundStyle(foregroundColor)
            .frame(width: 48, height: 48)
            .background(backgroundColor, in: Circle())
            .contentShape(Circle())
    }
}

private struct AlbumDownloadActionButton: View {
    let albumId: String
    let mode: AlbumDetailMode
    let viewModel: AlbumDetailViewModel?
    let downloadedAlbumTracks: [DownloadedTrack]
    let contentColor: Color
    let controlFillColor: Color
    @Binding var showDeleteAlert: Bool

    @Environment(\.appContainer) private var container

    private var state: AlbumDownloadControlState {
        if mode == .downloadedOnly {
            return downloadedAlbumTracks.isEmpty ? .unavailable : .removeDownloaded
        }
        guard let viewModel, !viewModel.isOffline else { return .unavailable }
        if viewModel.isDownloadingAlbum { return .cancel }

        switch AlbumDownloadState(songs: viewModel.songs) {
        case .notDownloaded:
            return viewModel.songs.isEmpty ? .unavailable : .download
        case .partiallyDownloaded:
            return .downloadMissing
        case .fullyDownloaded:
            return .removeDownloaded
        }
    }

    var body: some View {
        Button(action: performAction) {
            AlbumCircularActionLabel(
                systemImage: state.systemImage,
                foregroundColor: contentColor,
                backgroundColor: controlFillColor
            )
        }
        .disabled(state == .unavailable)
        .opacity(state == .unavailable ? 0.4 : 1)
        .accessibilityLabel(Text(actionLabel))
    }

    private var actionLabel: LocalizedStringResource {
        switch state {
        case .unavailable, .download: "Download Album"
        case .downloadMissing: "Download Missing Tracks"
        case .cancel: "Cancel Download"
        case .removeDownloaded: "Remove Download"
        }
    }

    private func performAction() {
        switch state {
        case .unavailable:
            break
        case .download:
            Task { await viewModel?.downloadAlbum() }
        case .downloadMissing:
            Task { await viewModel?.downloadMissingTracks() }
        case .cancel:
            Task { await viewModel?.cancelAlbumDownload() }
        case .removeDownloaded:
            if mode == .downloadedOnly {
                HapticFeedback.heavy.trigger()
                guard let container, let serverId = container.serverState.activeServer?.id else { return }
                Task {
                    await container.toastService.perform {
                        try await container.downloadService.remove(albumId: albumId, serverId: serverId)
                    }
                }
            } else {
                HapticFeedback.heavy.trigger()
                showDeleteAlert = true
            }
        }
    }
}

private struct AlbumDownloadProgress: View {
    let downloaded: Int
    let total: Int

    var body: some View {
        VStack(spacing: MinidiscSpacing.xs) {
            if downloaded == 0 {
                HStack(spacing: MinidiscSpacing.s) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Starting download…")
                }
            } else {
                ProgressView(value: Double(downloaded), total: Double(max(total, 1)))
                    .progressViewStyle(.linear)
                    .tint(MinidiscColors.accent)
                    .frame(maxWidth: 280)
                Text("Downloading \(downloaded)/\(total) tracks")
            }
        }
        .font(.minidiscCaption)
        .foregroundStyle(.secondary)
        .frame(minHeight: 44)
    }
}

private struct AlbumTrackSkeletonRows: View {
    var body: some View {
        ForEach(0..<5, id: \.self) { _ in
            HStack(spacing: MinidiscSpacing.m) {
                SkeletonBlock(width: 20, height: 20, cornerRadius: 4)
                SkeletonBlock(width: 200, height: 16, cornerRadius: 4)
                Spacer()
                SkeletonBlock(width: 24, height: 16, cornerRadius: 4)
            }
            .padding(.vertical, MinidiscSpacing.s)
            .padding(.horizontal, MinidiscSpacing.l)
        }
    }
}

// MARK: - Download state

private nonisolated enum AlbumDownloadState {
    case notDownloaded
    case partiallyDownloaded
    case fullyDownloaded

    init(songs: [DisplayableSong]) {
        guard !songs.isEmpty else {
            self = .notDownloaded
            return
        }
        let downloaded = songs.lazy.filter(\.isDownloaded).count
        if downloaded == 0 {
            self = .notDownloaded
        } else if downloaded == songs.count {
            self = .fullyDownloaded
        } else {
            self = .partiallyDownloaded
        }
    }
}

private nonisolated enum AlbumDownloadControlState: Equatable {
    case unavailable
    case download
    case downloadMissing
    case cancel
    case removeDownloaded

    var systemImage: String {
        switch self {
        case .unavailable, .download, .downloadMissing:
            "arrow.down"
        case .cancel:
            "xmark"
        case .removeDownloaded:
            "trash"
        }
    }
}

// MARK: - Live download indicator rows

/// Sub-view that observes DownloadedTrack changes live via @Query,
/// overriding the isDownloaded flag per row without requiring a VM reload.
struct AlbumSongRows: View {
    let songs: [DisplayableSong]
    let showArtists: Bool
    let downloadingIds: Set<String>
    let titleColor: Color
    let secondaryColor: Color
    let onTap: (Int) -> Void
    let onDownload: ((String) -> Void)?
    let onRemoveDownload: ((String) -> Void)?
    let onAddToPlaylist: ((DisplayableSong) -> Void)?

    @Query private var downloadedTracks: [DownloadedTrack]
    @Query private var allFavorites: [FavoriteRecord]

    private var favoriteSongIds: Set<String> {
        Set(allFavorites.map(\.id))
    }

    init(songs: [DisplayableSong], albumId: String, serverId: UUID, showArtists: Bool = false, downloadingIds: Set<String> = [], titleColor: Color = .primary, secondaryColor: Color = .secondary, onTap: @escaping (Int) -> Void, onDownload: ((String) -> Void)? = nil, onRemoveDownload: ((String) -> Void)? = nil, onAddToPlaylist: ((DisplayableSong) -> Void)? = nil) {
        self.songs = songs
        self.showArtists = showArtists
        self.downloadingIds = downloadingIds
        self.titleColor = titleColor
        self.secondaryColor = secondaryColor
        self.onTap = onTap
        self.onDownload = onDownload
        self.onRemoveDownload = onRemoveDownload
        self.onAddToPlaylist = onAddToPlaylist
        let aid = albumId
        let sid = serverId
        _downloadedTracks = Query(
            filter: #Predicate<DownloadedTrack> { track in
                track.albumId == aid && track.serverId == sid
            }
        )
    }

    private var downloadedSongIds: Set<String> {
        Set(downloadedTracks.map(\.songId))
    }

    var body: some View {
        ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
            let liveDownloaded = downloadedSongIds.contains(song.id)
            let liveSong = song.withDownloaded(liveDownloaded)
            let isDownloading = downloadingIds.contains(song.id)
            let downloadAction: (() -> Void)? = (liveDownloaded || isDownloading) ? nil : onDownload.map { action in { action(song.id) } }
            let removeAction: (() -> Void)? = liveDownloaded ? onRemoveDownload.map { action in { action(song.id) } } : nil
            VStack(spacing: 0) {
                SongRow(song: liveSong, index: index + 1, showArtist: showArtists, isFavorite: favoriteSongIds.contains("song:\(song.id)"), titleColor: titleColor, secondaryColor: secondaryColor, trailingAccessory: .menu, onDownload: downloadAction, onRemoveDownload: removeAction, isDownloading: isDownloading, onAddToPlaylist: onAddToPlaylist, onTap: { onTap(index) })
                    .padding(.vertical, MinidiscSpacing.xs)
                    .padding(.horizontal, MinidiscSpacing.l)
                if index < songs.count - 1 {
                    Divider()
                        .overlay(titleColor.opacity(0.22))
                        .padding(.leading, MinidiscSpacing.l + 36)
                }
            }
        }
    }
}

// MARK: - Release information

/// Compact album facts supplied by Subsonic/OpenSubsonic metadata. Every line is optional so
/// sparse or offline libraries show only facts Minidisc can support without guessing.
private struct AlbumReleaseInformationSection: View {
    let releaseDate: ItemDate?
    let fallbackYear: Int?
    let songCount: Int
    let totalDuration: TimeInterval
    let releaseTypes: [String]
    let version: String?
    let recordLabels: [String]
    let audioFormats: [String]
    let textColor: Color

    private var dateText: String? {
        guard let year = releaseDate?.year ?? fallbackYear else { return nil }
        guard let month = releaseDate?.month else { return String(year) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = releaseDate?.day ?? 1
        guard let date = calendar.date(from: components) else { return String(year) }

        if releaseDate?.day != nil {
            return date.formatted(.dateTime.day().month(.wide).year())
        }
        return date.formatted(.dateTime.month(.wide).year())
    }

    private var countAndDurationText: String? {
        guard songCount > 0 else { return nil }
        let count = String(localized: "\(songCount) songs")
        guard totalDuration > 0 else { return count }
        let duration = Duration.seconds(totalDuration).formatted(
            .units(allowed: [.hours, .minutes], width: .wide, maximumUnitCount: 2)
        )
        return "\(count), \(duration)"
    }

    private var descriptorText: String? {
        uniqueValues(
            releaseTypes.map { $0.localizedCapitalized }
                + [version].compactMap { $0 }
                + audioFormats.map { $0.uppercased() }
        )
        .joined(separator: " · ")
        .nilIfEmpty
    }

    private var labelText: String? {
        uniqueValues(recordLabels).joined(separator: " · ").nilIfEmpty
    }

    private var hasContent: Bool {
        dateText != nil || countAndDurationText != nil || descriptorText != nil || labelText != nil
    }

    var body: some View {
        if hasContent {
            VStack(alignment: .leading, spacing: 3) {
                if let dateText {
                    Text(verbatim: dateText)
                }
                if let countAndDurationText {
                    Text(verbatim: countAndDurationText)
                }
                if let descriptorText {
                    Text(verbatim: descriptorText)
                }
                if let labelText {
                    Text(verbatim: labelText)
                }
            }
            .font(.footnote)
            .foregroundStyle(textColor.opacity(0.82))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, MinidiscSpacing.l)
            .padding(.top, MinidiscSpacing.l)
            .accessibilityElement(children: .combine)
        }
    }

    private func uniqueValues(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { return nil }
            return trimmed
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - More by artist

/// A supplementary shelf, loaded independently so a slow artist lookup never delays the album or its tracks.
private struct AlbumMoreByArtistSection: View {
    let artistId: String
    let artistName: String
    let currentAlbumId: String

    @Environment(\.appContainer) private var container
    @State private var albums: [AlbumID3] = []

    private var sectionTitle: LocalizedStringResource {
        "More by \(artistName)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !albums.isEmpty {
                MinidiscShelf {
                    MinidiscCarouselHeaderLink(
                        sectionTitle,
                        itemCount: albums.count,
                        hasMore: true
                    ) {
                        ArtistDetailView(
                            artistId: artistId,
                            artistName: artistName,
                            coverArtId: nil
                        )
                    }
                } content: {
                    ForEach(albums) { album in
                        AlbumShelfCard(album: album)
                    }
                }
            }
        }
        .padding(.top, MinidiscSpacing.xxl)
        .padding(.bottom, MinidiscSpacing.xxl)
        .task(id: artistId) {
            await loadAlbums()
        }
    }

    private func loadAlbums() async {
        guard let container, container.serverState.isOnline else {
            albums = []
            return
        }

        do {
            let artist = try await container.libraryService.artist(id: artistId)
            try Task.checkCancellation()
            albums = Array(
                (artist.album ?? [])
                    .lazy
                    .filter { $0.id != currentAlbumId }
                    .prefix(MinidiscCarouselMetrics.previewLimit)
            )
        } catch is CancellationError {
            return
        } catch {
            albums = []
            Logger.library.warning(
                "Unable to load related albums for artist \(artistId, privacy: .public): \(error, privacy: .public)"
            )
        }
    }
}

// MARK: - You might also like

/// Album-level recommendations derived from Navidrome's similar-song graph.
/// Loading is independent from the primary album so an unavailable recommendation provider never delays playback.
private struct AlbumYouMightAlsoLikeSection: View {
    let albums: [AlbumID3]

    static let resultLimit = MinidiscCarouselMetrics.previewLimit * 2

    var body: some View {
        if !albums.isEmpty {
            MinidiscShelf {
                MinidiscCarouselHeaderLink(
                    "You Might Also Like",
                    itemCount: albums.count
                ) {
                    AlbumCarouselCollectionView(
                        "You Might Also Like",
                        albums: albums
                    )
                }
            } content: {
                ForEach(Array(albums.prefix(MinidiscCarouselMetrics.previewLimit))) { album in
                    AlbumShelfCard(album: album)
                }
            }
            .padding(.bottom, MinidiscSpacing.xxl)
        }
    }
}

// MARK: - Theme colour sheet

/// Host for the album's theme-colour override. A ColorPicker cannot be placed inside a Menu, so the
/// overflow menu opens this instead — which also gives "Reset to cover colour" a visible home rather
/// than the long-press-only contextMenu it used to live in.
struct ThemeColorSheet: View {
    @Binding var color: Color
    let hasOverride: Bool
    var footerText: LocalizedStringKey = "Overrides the colour taken from the cover, here and anywhere else this appears."
    let onReset: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ColorPicker("Theme colour", selection: $color, supportsOpacity: false)
                } footer: {
                    Text(footerText)
                }
                if hasOverride {
                    Section {
                        Button("Reset to cover colour", systemImage: "arrow.uturn.backward", role: .destructive) {
                            onReset()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Theme colour")
            .navigationBarTitleDisplayModeInline()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.height(260)])
    }
}
