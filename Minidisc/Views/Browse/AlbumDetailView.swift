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

    /// `viewModel` is for Previews: a supplied model is loaded instead of one built from the container.
    init(album: AlbumID3, zoomSourceId: String? = nil, zoomNamespace: Namespace.ID? = nil, coverArtId: String? = nil, initialDominantColor: Color = .clear, initialCoverImage: PlatformImage? = nil, mode: AlbumDetailMode = .full, viewModel: AlbumDetailViewModel? = nil) {
        _viewModel = State(initialValue: viewModel)
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
    @State private var songSelection: SongSelectionRequest?
    @Environment(\.dismiss) private var dismiss
    @Environment(DominantColorExtractor.self) private var colorExtractor
    @Environment(ArtworkImageCache.self) private var artworkImageCache
    @Environment(\.colorScheme) private var colorScheme
    @State private var viewModel: AlbumDetailViewModel?
    @State private var dominantColor: Color = .clear
    @State private var showDeleteAlert = false
    @State private var showThemeColorSheet = false
    @State private var recommendedAlbums: [AlbumID3] = []
    @State private var similarArtists: [SimilarArtistRecommendation] = []
    @State private var similarArtistImages: [String: URL?] = [:]
    @State private var isLoadingSimilarArtists = false
    @State private var selectedOutOfLibraryArtist: SimilarArtistRecommendation?
    @State private var artistPicker: ArtistPickerRequest?
    @State private var pushedArtist: ArtistID3?
    @Query private var albumFavoriteMatches: [FavoriteRecord]
    @Query private var downloadedAlbumTracks: [DownloadedTrack]

    private var isAlbumFavorite: Bool { !albumFavoriteMatches.isEmpty }
    private var isOnline: Bool { container?.serverState.isOnline == true }
    private var albumCoverId: String { viewModel?.coverArtId ?? coverArtId ?? albumId }
    /// Every cover id the override must cover so it's resolved from ANY surface: the album cover + each song's
    /// own cover id (these can differ from the album's while pointing at the same artwork — e.g. the full player).
    private var albumThemeIds: [String] {
        [albumCoverId] + (viewModel?.songs.compactMap { $0.coverArtId } ?? [])
    }
    private func resetThemeColor() {
        colorExtractor.setColorOverride(nil, forIds: albumThemeIds)
        dominantColor = colorExtractor.cachedColor(for: albumCoverId) ?? dominantColor
    }
    private var isLoadingSkeleton: Bool {
        viewModel == nil || (viewModel?.isLoading == true && viewModel?.songs.isEmpty == true)
    }
    private var palette: AlbumDetailPalette {
        AlbumDetailPalette(dominantColor: dominantColor)
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
        if !isOnline {
            let local = container?.offlineLibrary.snapshot.albumSongs(albumId) ?? []
            return mode == .downloadedOnly ? local.filter(\.isDownloaded) : local
        }
        switch mode {
        case .downloadedOnly:
            if let vm = viewModel, vm.error == nil, !vm.songs.isEmpty {
                return filteredSongs(vm.songs)
            }
            return offlineFallbackSongs
        case .full:
            // Fall back to downloaded tracks if the catalogue fails or returns an empty response.
            if let vm = viewModel, !vm.songs.isEmpty {
                return vm.songs
            }
            return offlineFallbackSongs
        }
    }

    // MARK: - Artist navigation

    /// One credited artist opens directly; several open the picker.
    private func openArtists(_ credits: [ArtistCredit], trackTitle: String) {
        if credits.count == 1, let credit = credits.first {
            open(credit)
        } else if !credits.isEmpty {
            artistPicker = ArtistPickerRequest(trackTitle: trackTitle, credits: credits)
        }
    }

    private func open(_ credit: ArtistCredit) {
        if let id = credit.id, !id.isEmpty {
            pushedArtist = ArtistID3(id: id, name: credit.name)
            return
        }
        // Credits parsed from a plain artist string carry no ID; resolve it by name.
        Task {
            if let found = await container?.libraryService.findArtist(byName: credit.name) {
                pushedArtist = found
            } else {
                container?.toastService.showError(String(localized: "\(credit.name) isn’t in your library."))
            }
        }
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
                    isOffline: viewModel?.isOffline == true,
                    songCount: songs.count,
                    totalDuration: songs.reduce(0) { $0 + $1.duration },
                    audioFormats: songs.compactMap(\.audioFormat),
                    genres: viewModel?.genres ?? [],
                    recordLabels: viewModel?.recordLabels ?? []
                )
                .padding(.top, MinidiscSpacing.xl)

                AlbumPlaybackActions(
                    albumId: albumId,
                    songs: songs,
                    mode: mode,
                    viewModel: viewModel,
                    downloadedAlbumTracks: downloadedAlbumTracks,
                    isFavorite: isAlbumFavorite,
                    canFavorite: isOnline,
                    onToggleFavorite: toggleAlbumFavorite,
                    showDeleteAlert: $showDeleteAlert
                )
                .padding(.top, MinidiscSpacing.xl)
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
                            showArtists: true,
                            downloadingIds: vm.downloadingIds,
                            titleColor: headerTextColor,
                            secondaryColor: headerSecondaryColor,
                            albumArtistId: vm.artistId,
                            albumArtistName: vm.artistName,
                            discTitles: vm.discTitles,
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
                            onAddToPlaylist: playlistAddition.present,
                            onArtistsTap: isOnline && !vm.isOffline ? { song, credits in
                                openArtists(credits, trackTitle: song.title)
                            } : nil
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

                            if isLoadingSimilarArtists || !similarArtists.isEmpty {
                                SimilarArtistsShelf(
                                    recommendations: similarArtists,
                                    imageURLs: similarArtistImages,
                                    isLoading: isLoadingSimilarArtists,
                                    onOutOfLibraryTap: { selectedOutOfLibraryArtist = $0 }
                                )
                                .padding(.top, MinidiscSpacing.section)
                            }

                            AlbumYouMightAlsoLikeSection(albums: visibleRecommendedAlbums)
                        }

                        // Breathing room before the mini player margin, whichever section ends the page.
                        Color.clear.frame(height: MinidiscSpacing.section)
                    }
                }
            }
        }
        .refreshable { await viewModel?.load() }
        .miniPlayerBottomMargin()
        .minidiscHideTopScrollEdgeEffect()
        .minidiscSongSwipeContainer()
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
                Menu("More options", systemImage: "ellipsis") {
                    Group {
                        Button("Select Songs", systemImage: "checkmark.circle") {
                            songSelection = SongSelectionRequest(songs: displaySongs())
                        }
                        .disabled(container?.serverState.isOnline != true || displaySongs().isEmpty)
                        Divider()
                        Button("Instant Mix", systemImage: instantMixSymbol) {
                            HapticFeedback.medium.trigger()
                            startInstantMix(from: .album(id: albumId), using: container)
                        }
                        .disabled(displaySongs().isEmpty || !isOnline)
                        Divider()
                        // ColorPicker requires a sheet rather than Menu content.
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
        .sheet(item: $songSelection) { SongSelectionSheet(request: $0) }
        .sheet(item: $artistPicker) { request in
            ArtistPickerSheet(request: request) { open($0) }
        }
        .sheet(item: $selectedOutOfLibraryArtist) { recommendation in
            OutOfLibraryArtistSheet(
                artist: recommendation,
                imageURL: similarArtistImages[recommendation.id] ?? nil,
                providers: container?.externalProvidersStore.load() ?? []
            )
        }
        .navigationDestination(item: $pushedArtist) { artist in
            ArtistDetailView(artist: artist)
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
        .task(id: container?.serverState.isOnline) {
            guard let c = container else { return }
            if viewModel == nil {
                viewModel = AlbumDetailViewModel(
                    albumId: albumId,
                    libraryService: c.libraryService,
                    downloadService: c.downloadService,
                    toastService: c.toastService,
                    serverState: c.serverState,
                    offlineFavorites: mode == .downloadedOnly ? nil : c.offlineFavoritesStore
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
        .task(id: similarArtistsRequestID) {
            await loadSimilarArtists()
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

    // MARK: - Favourite

    private func toggleAlbumFavorite() {
        HapticFeedback.light.trigger()
        let wasFavorite = isAlbumFavorite
        Task {
            if wasFavorite {
                await container?.toastService.perform { try await container?.favoritesService.unstar(itemType: .album, itemId: albumId) }
            } else {
                await container?.toastService.perform { try await container?.favoritesService.star(itemType: .album, itemId: albumId) }
            }
        }
    }

    // MARK: - Similar artists

    /// Changes when the album artist is known, so the shelf loads once per artist and only online.
    private var similarArtistsRequestID: String? {
        guard case .full = mode, isOnline, viewModel?.isOffline != true else { return nil }
        return viewModel?.artistId
    }

    private func loadSimilarArtists() async {
        guard let artistId = similarArtistsRequestID, let container else {
            similarArtists = []
            return
        }
        isLoadingSimilarArtists = true
        defer { isLoadingSimilarArtists = false }
        do {
            let recommendations = try await container.recommendationService.similarArtists(to: artistId)
            try Task.checkCancellation()
            similarArtists = recommendations
        } catch is CancellationError {
            return
        } catch {
            similarArtists = []
            Logger.recommendations.warning(
                "Album similar artists failed for \(artistId, privacy: .public): \(error, privacy: .public)"
            )
            return
        }
        for recommendation in similarArtists where !recommendation.inLibrary {
            let url = await container.externalArtistImageResolver.resolveImageURL(for: recommendation)
            guard !Task.isCancelled else { return }
            similarArtistImages[recommendation.id] = url
        }
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

/// Album pages are always dark: a cover-tinted surface with white content, whatever the system
/// appearance (see `ArtworkSurfacePalette`).
struct AlbumDetailPalette {
    let tint: Color
    let contentColor: Color = .white
    let secondaryContentColor: Color = .white.opacity(0.7)
    let controlFillColor: Color = .white.opacity(0.16)
    let preferredContentScheme: ColorScheme? = .dark

    init(dominantColor: Color) {
        tint = ArtworkSurfacePalette.tint(from: dominantColor)
    }
}

struct AlbumDetailPageBackground: View {
    let palette: AlbumDetailPalette

    var body: some View {
        ArtworkSurfaceBackground(tint: palette.tint)
    }
}

struct AlbumArtworkSection: View {
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

struct AlbumMetadataSection: View {
    let albumName: String
    let artistName: String?
    let artistId: String?
    let year: Int?
    let genre: String?
    let isLoading: Bool
    let isOffline: Bool
    var songCount: Int = 0
    var totalDuration: TimeInterval = 0
    var audioFormats: [String] = []
    var genres: [String] = []
    var recordLabels: [String] = []

    var body: some View {
        VStack(spacing: MinidiscSpacing.xs) {
            Text(albumName)
                .font(.minidiscDetailTitle)
                .multilineTextAlignment(.center)
                .lineLimit(2)

            if isLoading {
                SkeletonBlock(width: 140, height: 18, cornerRadius: 4)
            } else if let artistName {
                if let artistId, !isOffline {
                    NavigationLink(value: HomeDestination.artist(ArtistID3(id: artistId, name: artistName))) {
                        Text(artistName)
                            .font(.minidiscDetailSubtitle)
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text("Opens the artist"))
                } else {
                    Text(artistName)
                        .font(.minidiscDetailSubtitle)
                        .foregroundStyle(.primary)
                }
            }

            if isLoading {
                SkeletonBlock(width: 100, height: 14, cornerRadius: 4)
                    .padding(.top, MinidiscSpacing.xs)
            } else {
                AlbumMetadataLine(
                    year: year,
                    songCount: songCount,
                    totalDuration: totalDuration,
                    audioFormats: audioFormats
                )
                .padding(.top, MinidiscSpacing.xs)

                let chips = genreChips + labelChips
                if !chips.isEmpty {
                    MetadataChipFlow {
                        ForEach(chips, id: \.self) { chip in
                            if isOffline {
                                MetadataChip(text: chip.text, systemImage: chip.systemImage)
                            } else {
                                // Opens every album in that genre / from that label.
                                NavigationLink {
                                    AlbumCollectionView(kind: chip.kind)
                                } label: {
                                    MetadataChip(text: chip.text, systemImage: chip.systemImage)
                                }
                                .buttonStyle(.plain)
                                .accessibilityHint(Text("Shows all albums"))
                            }
                        }
                    }
                    .padding(.top, MinidiscSpacing.s)
                }
            }
        }
        .padding(.horizontal, MinidiscSpacing.xxl)
    }

    private struct Chip: Hashable {
        let text: String
        let systemImage: String?
        let kind: AlbumCollectionKind
    }

    private var genreChips: [Chip] {
        let values = genres.isEmpty ? [genre].compactMap { $0 } : genres
        return Self.unique(values).prefix(3).map { Chip(text: $0, systemImage: nil, kind: .genre($0)) }
    }

    private var labelChips: [Chip] {
        Self.unique(recordLabels).prefix(1).map { Chip(text: $0, systemImage: "building.2", kind: .recordLabel($0)) }
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { return nil }
            return trimmed
        }
    }
}

/// "2023 · 10 songs · 38 min [FLAC]" under the album artist.
private struct AlbumMetadataLine: View {
    let year: Int?
    let songCount: Int
    let totalDuration: TimeInterval
    let audioFormats: [String]

    private var parts: [String] {
        var parts: [String] = []
        if let year { parts.append(String(year)) }
        if songCount > 0 { parts.append(String(localized: "\(songCount) songs")) }
        if totalDuration > 0 {
            parts.append(Duration.seconds(totalDuration).formatted(
                .units(allowed: [.hours, .minutes], width: .abbreviated, maximumUnitCount: 2)
            ))
        }
        return parts
    }

    /// One badge per distinct format; mixed-format albums show at most two.
    private var formats: [String] {
        var seen: Set<String> = []
        return audioFormats.map { $0.uppercased() }.filter { seen.insert($0).inserted }.prefix(2).map { $0 }
    }

    var body: some View {
        HStack(spacing: MinidiscSpacing.s) {
            if !parts.isEmpty {
                Text(verbatim: parts.joined(separator: " · "))
                    .lineLimit(1)
            }
            ForEach(formats, id: \.self) { format in
                FormatBadge(format: format)
            }
        }
        .font(.minidiscMetadata)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}

/// Favourite · Play · Shuffle · Download, as a row of round buttons.
private struct AlbumPlaybackActions: View {
    let albumId: String
    let songs: [DisplayableSong]
    let mode: AlbumDetailMode
    let viewModel: AlbumDetailViewModel?
    let downloadedAlbumTracks: [DownloadedTrack]
    let isFavorite: Bool
    let canFavorite: Bool
    let onToggleFavorite: () -> Void
    @Binding var showDeleteAlert: Bool

    @Environment(\.appContainer) private var container

    var body: some View {
        VStack(spacing: MinidiscSpacing.m) {
            HStack(spacing: MinidiscSpacing.xl) {
                Button(isFavorite ? "Remove from Favorites" : "Add to Favorites",
                       systemImage: isFavorite ? "heart.fill" : "heart",
                       action: onToggleFavorite)
                    .contentTransition(.symbolEffect(.replace))
                    .buttonStyle(.minidiscCircle(diameter: MinidiscControlSize.large))
                    .disabled(!canFavorite)
                    .accessibilityIdentifier("album.detail.favorite")

                Button("Play", systemImage: "play.fill") {
                    HapticFeedback.medium.trigger()
                    Task {
                        guard !songs.isEmpty else { return }
                        await container?.toastService.perform { try await container?.playerService.play(tracks: songs, startIndex: 0) }
                    }
                }
                .buttonStyle(.minidiscCircle(diameter: MinidiscControlSize.large, isProminent: true))
                .disabled(songs.isEmpty)
                .accessibilityIdentifier("album.detail.play")

                Button("Shuffle", systemImage: "shuffle") {
                    HapticFeedback.medium.trigger()
                    Task {
                        guard !songs.isEmpty else { return }
                        await container?.toastService.perform { try await container?.playerService.play(tracks: songs.shuffled(), startIndex: 0) }
                    }
                }
                .buttonStyle(.minidiscCircle(diameter: MinidiscControlSize.large))
                .disabled(songs.isEmpty)
                .accessibilityIdentifier("album.detail.shuffle")

                AlbumDownloadActionButton(
                    albumId: albumId,
                    mode: mode,
                    viewModel: viewModel,
                    downloadedAlbumTracks: downloadedAlbumTracks,
                    showDeleteAlert: $showDeleteAlert
                )
            }

            if mode == .full, let viewModel, viewModel.isDownloadingAlbum {
                AlbumDownloadProgress(
                    downloaded: downloadedAlbumTracks.count,
                    total: viewModel.songs.count
                )
            }
        }
    }
}

private struct AlbumDownloadActionButton: View {
    let albumId: String
    let mode: AlbumDetailMode
    let viewModel: AlbumDetailViewModel?
    let downloadedAlbumTracks: [DownloadedTrack]
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
            Image(systemName: state.systemImage)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.minidiscCircle(diameter: MinidiscControlSize.large))
        .disabled(state == .unavailable)
        .accessibilityLabel(Text(actionLabel))
        .accessibilityIdentifier("album.detail.download")
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

struct AlbumSongRows: View {
    let songs: [DisplayableSong]
    let showArtists: Bool
    let downloadingIds: Set<String>
    let titleColor: Color
    let secondaryColor: Color
    let albumArtistId: String?
    let albumArtistName: String?
    let discTitles: [Int: String]
    let onTap: (Int) -> Void
    let onDownload: ((String) -> Void)?
    let onRemoveDownload: ((String) -> Void)?
    let onAddToPlaylist: ((DisplayableSong) -> Void)?
    /// Receives a track's credits when its artist line is tapped. `nil` shows plain, untappable artists.
    let onArtistsTap: ((DisplayableSong, [ArtistCredit]) -> Void)?

    @Query private var downloadedTracks: [DownloadedTrack]
    @Query private var allFavorites: [FavoriteRecord]

    private var favoriteSongIds: Set<String> {
        Set(allFavorites.map(\.id))
    }

    init(songs: [DisplayableSong], albumId: String, serverId: UUID, showArtists: Bool = false, downloadingIds: Set<String> = [], titleColor: Color = .primary, secondaryColor: Color = .secondary, albumArtistId: String? = nil, albumArtistName: String? = nil, discTitles: [Int: String] = [:], onTap: @escaping (Int) -> Void, onDownload: ((String) -> Void)? = nil, onRemoveDownload: ((String) -> Void)? = nil, onAddToPlaylist: ((DisplayableSong) -> Void)? = nil, onArtistsTap: ((DisplayableSong, [ArtistCredit]) -> Void)? = nil) {
        self.songs = songs
        self.showArtists = showArtists
        self.downloadingIds = downloadingIds
        self.titleColor = titleColor
        self.secondaryColor = secondaryColor
        self.albumArtistId = albumArtistId
        self.albumArtistName = albumArtistName
        self.discTitles = discTitles
        self.onTap = onTap
        self.onDownload = onDownload
        self.onRemoveDownload = onRemoveDownload
        self.onAddToPlaylist = onAddToPlaylist
        self.onArtistsTap = onArtistsTap
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

    /// Disc headers appear only when the album spans more than one disc.
    private var isMultiDisc: Bool {
        Set(songs.map { $0.discNumber ?? 1 }).count > 1
    }

    var body: some View {
        let multiDisc = isMultiDisc
        ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
            let liveDownloaded = downloadedSongIds.contains(song.id)
            let liveSong = song.withDownloaded(liveDownloaded)
            let isDownloading = downloadingIds.contains(song.id)
            let downloadAction: (() -> Void)? = (liveDownloaded || isDownloading) ? nil : onDownload.map { action in { action(song.id) } }
            let removeAction: (() -> Void)? = liveDownloaded ? onRemoveDownload.map { action in { action(song.id) } } : nil
            let credits = TrackArtistCredits.credits(for: song, albumArtistID: albumArtistId, albumArtistName: albumArtistName)
            let disc = song.discNumber ?? 1
            VStack(spacing: 0) {
                if multiDisc, index == 0 || (songs[index - 1].discNumber ?? 1) != disc {
                    DiscHeader(discNumber: disc, title: discTitles[disc])
                        .foregroundStyle(titleColor)
                }
                SongRow(
                    song: liveSong,
                    index: index + 1,
                    showArtist: showArtists && !credits.isEmpty,
                    isFavorite: favoriteSongIds.contains("song:\(song.id)"),
                    titleColor: titleColor,
                    secondaryColor: secondaryColor,
                    trailingAccessory: .favorite,
                    rowAccessibilityIdentifier: "album.song.row.\(song.id)",
                    onDownload: downloadAction,
                    onRemoveDownload: removeAction,
                    isDownloading: isDownloading,
                    onAddToPlaylist: onAddToPlaylist,
                    artistCredits: credits,
                    onArtistsTap: onArtistsTap.map { handler in { handler(song, $0) } },
                    onTap: { onTap(index) }
                )
                .padding(.leading, MinidiscSpacing.l)
                .padding(.trailing, MinidiscSpacing.trackRowTrailing)
            }
        }
    }
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
        // Spacing only when the shelf shows, so an artist with one album leaves no gap.
        .padding(.top, albums.isEmpty ? 0 : MinidiscSpacing.section)
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
            .padding(.top, MinidiscSpacing.section)
        }
    }
}

// MARK: - Theme colour sheet

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

#if DEBUG
#Preview("Album") {
    let container = AppContainer.preview()
    let album = PreviewFixtures.tidalRooms
    MinidiscPreview(container: container) {
        NavigationStack {
            AlbumDetailView(
                album: album,
                coverArtId: album.coverArt,
                viewModel: .preview(albumId: album.id, container: container)
            )
        }
    }
}

#Preview("Album, two discs, large text") {
    let container = AppContainer.preview()
    let album = PreviewFixtures.fieldRecordings
    MinidiscPreview(container: container) {
        NavigationStack {
            AlbumDetailView(
                album: album,
                coverArtId: album.coverArt,
                viewModel: .preview(albumId: album.id, container: container)
            )
        }
    }
    .dynamicTypeSize(.xxLarge)
}
#endif
