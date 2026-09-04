import SwiftUI
import SwiftSonic
import SwiftData

private enum PreparedArtistShare: Hashable, Identifiable {
    case link(URL)
    case text(String)

    var id: Self { self }
}

struct ArtistDetailView: View {
    let artist: ArtistID3

    @Environment(\.appContainer) private var container
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: ArtistDetailViewModel?
    @State private var selectedOutOfLibraryArtist: SimilarArtistRecommendation?
    @State private var isShowingArtistInformation = false
    @State private var preparedArtistShare: PreparedArtistShare?
    @Query private var artistFavoriteMatches: [FavoriteRecord]
    /// Keeps fetched liked songs reactive to local favorite changes.
    @Query(filter: #Predicate<FavoriteRecord> { $0.itemType == "song" })
    private var songFavorites: [FavoriteRecord]
    @Environment(DominantColorExtractor.self) private var colorExtractor
    @Environment(\.colorScheme) private var colorScheme
    @State private var dominantColor: Color = .clear
    @AppStorage("minidisc.albumSort") private var albumSort: AlbumSort = .recentlyAdded
    private let heroCoverHeight: CGFloat = 500
    @State private var isGeneratingMix = false

    init(artist: ArtistID3) {
        self.artist = artist
        let cid = "artist:\(artist.id)"
        _artistFavoriteMatches = Query(filter: #Predicate<FavoriteRecord> { $0.id == cid })
    }

    init(artistId: String, artistName: String, coverArtId: String?) {
        self.init(artist: ArtistID3(id: artistId, name: artistName, coverArt: coverArtId))
    }

    private var isArtistFavorite: Bool { !artistFavoriteMatches.isEmpty }
    private var isOnline: Bool { container?.serverState.isOnline == true }

    // MARK: - Theming

    private var theme: PlaylistTheme { PlaylistTheme(dominantColor: dominantColor) }
    private var bodyColor: Color { theme.isThemed ? theme.dominantColor : systemBackgroundColor }
    private var headerTextColor: Color { theme.contentColor }
    private var headerSecondaryColor: Color { theme.secondaryContentColor }
    private var systemBackgroundColor: Color {
        Color(UIColor.systemBackground)
    }
    private var heroCoverArtId: String {
        if let cover = viewModel?.artist?.coverArt, !cover.isEmpty { return cover }
        if let latest = latestReleaseCoverArtId { return latest }
        return artist.id
    }
    private var latestReleaseCoverArtId: String? {
        viewModel.flatMap { latestRelease($0) }?.coverArt
    }

    private let columns = [
        GridItem(.adaptive(minimum: 150, maximum: 200), spacing: MinidiscSpacing.l)
    ]

    var body: some View {
        Group {
            if let vm = viewModel {
                if let error = vm.error, vm.artist == nil {
                    EmptyStateView(
                        systemImage: "exclamationmark.triangle",
                        title: "Unable to Load Artist",
                        subtitle: LocalizedStringKey(error.displayMessage),
                        action: .init(label: "Retry") { Task { await vm.load() } }
                    )
                } else {
                    let albums = vm.artist?.album ?? []
                    if albums.isEmpty {
                        if vm.isOffline || !isOnline {
                            EmptyStateView(
                                systemImage: "wifi.slash",
                                title: "You're Offline",
                                subtitle: "Nothing from this artist is downloaded. Download albums while online to browse them here."
                            )
                        } else {
                            EmptyStateView(
                                systemImage: "square.stack",
                                title: "No Albums",
                                subtitle: "This artist has no albums in the library."
                            )
                        }
                    } else {
                        ScrollView {
                            artistHero(vm: vm)
                            VStack(alignment: .leading, spacing: MinidiscSpacing.xl) {
                                // Hidden offline: downloads carry no release year, so "Latest" would be
                                // an arbitrary pick.
                                if !vm.isOffline, let featured = latestRelease(vm) {
                                    featuredReleaseSection(featured)
                                }
                                if vm.isLoadingTopSongs {
                                    ArtistTopSongsSkeleton()
                                } else if !vm.topSongs.isEmpty {
                                    ArtistTopSongsSection(
                                        artistName: artist.name,
                                        songs: vm.topSongs,
                                        titleColor: headerTextColor,
                                        secondaryColor: headerSecondaryColor
                                    )
                                }
                                // Both forms of the liked tracks occupy the SAME slot: few of them list
                                // inline, enough of them collapse into the best-of card. Crossing the
                                // threshold swaps the content in place instead of moving the discography.
                                let liked = likedSongs(vm)
                                if vm.isLoadingLikedSongs {
                                    likedSongsSkeleton
                                } else if liked.count >= ArtistBestOf.minimumSongs {
                                    bestOfSection(liked)
                                } else if !liked.isEmpty {
                                    likedSongsSection(liked)
                                }
                                if !vm.albumReleases.isEmpty {
                                    ArtistAlbumShelf(
                                        title: "Albums",
                                        albums: albumSort.sorted(vm.albumReleases)
                                    )
                                }
                                if !vm.singlesAndEPs.isEmpty {
                                    ArtistAlbumShelf(
                                        title: "Singles & EPs",
                                        albums: albumSort.sorted(vm.singlesAndEPs)
                                    )
                                }
                                if vm.isLoadingSimilarArtists || !vm.similarArtists.isEmpty {
                                    ArtistSimilarArtistsShelf(
                                        recommendations: vm.similarArtists,
                                        imageURLs: vm.outOfLibraryArtistImages,
                                        isLoading: vm.isLoadingSimilarArtists,
                                        onOutOfLibraryTap: { selectedOutOfLibraryArtist = $0 }
                                    )
                                }
                            }
                            .padding(.vertical, MinidiscSpacing.l)
                            .frame(maxWidth: .infinity)
                            .background(bodyColor)
                            // Force the themed scheme so the shared cells contrast the tinted body.
                            .environment(\.colorScheme, theme.isThemed ? (theme.isLight ? .light : .dark) : colorScheme)
                        }
                        .ignoresSafeArea(.container, edges: .top)
                        .minidiscHideTopScrollEdgeEffect()
                        .background(bodyColor.ignoresSafeArea())
                        .refreshable {
                            await vm.load()
                            await vm.loadLikedSongs()
                        }
                        .task(id: heroCoverArtId) {
                            let cached = colorExtractor.bottomStripColor(for: heroCoverArtId, image: nil)
                            if cached != .clear {
                                dominantColor = cached
                            } else {
                                await loadDominantColor(coverArtId: heroCoverArtId)
                            }
                        }
                    }
                }
            } else {
                skeletonGrid
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayModeInline()
        .navigationBarBackButtonHidden(true)
        .enableSwipeBack()
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(theme.isThemed ? (theme.isLight ? .light : .dark) : nil, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Back", systemImage: "chevron.left") {
                    dismiss()
                }
                .tint(headerTextColor)
            }

            ToolbarItem(placement: .primaryAction) {
                Button("Share", systemImage: "square.and.arrow.up") {
                    prepareArtistShare()
                }
                .tint(headerTextColor)
            }

            ToolbarItem(placement: .primaryAction) {
                Menu("More options", systemImage: "ellipsis") {
                    Button("Automix", systemImage: instantMixSymbol) {
                        startArtistAutomix()
                    }
                    .disabled(!canStartArtistAutomix)
                }
                .tint(headerTextColor)
            }
        }
        // Keyed on connectivity so going offline (or coming back) re-resolves the artist against the
        // right source, as the album and playlist screens already do.
        .task(id: container?.serverState.isOnline) {
            guard let c = container else { return }
            if viewModel == nil {
                viewModel = ArtistDetailViewModel(
                    artistId: artist.id,
                    artistName: artist.name,
                    libraryService: c.libraryService,
                    downloadService: c.downloadService,
                    recommendationService: c.recommendationService,
                    imageResolver: c.externalArtistImageResolver,
                    serverState: c.serverState
                )
            }
            await viewModel?.load()
            guard let viewModel else { return }
            async let artistInfo: Void = viewModel.loadArtistInfo()
            await viewModel.loadTopSongs()
            await viewModel.loadLikedSongs()
            await viewModel.loadSimilarArtists()
            await artistInfo
        }
        .sheet(isPresented: $isShowingArtistInformation) {
            ArtistInformationSheet(
                artist: viewModel?.artist ?? artist,
                biography: viewModel?.biography,
                lastFmURL: viewModel?.lastFmURL,
                isLoadingBiography: viewModel?.isLoadingArtistInfo == true,
                dominantColor: dominantColor
            )
        }
        .sheet(item: $preparedArtistShare) { share in
            artistShareSheet(for: share)
        }
        .sheet(item: $selectedOutOfLibraryArtist) { rec in
            OutOfLibraryArtistSheet(
                artist: rec,
                imageURL: viewModel?.outOfLibraryArtistImages[rec.id] ?? nil,
                providers: container?.externalProvidersStore.load() ?? []
            )
        }
    }

    // MARK: - Hero

    private func artistHero(vm: ArtistDetailViewModel) -> some View {
        let albums = vm.artist?.album ?? []
        return ImmersiveCoverHero(
            coverArtId: heroCoverArtId,
            coverImage: nil,
            theme: theme,
            heroHeight: heroCoverHeight
        ) {
            heroContent(vm: vm, albums: albums)
                .padding(.horizontal, MinidiscSpacing.l)
        }
    }

    private func heroContent(vm: ArtistDetailViewModel, albums: [AlbumID3]) -> some View {
        VStack(spacing: MinidiscSpacing.xl) {
            Text(artist.name)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .foregroundStyle(headerTextColor)
                .multilineTextAlignment(.center)

            HStack(spacing: MinidiscSpacing.xxl) {
                Button {
                    isShowingArtistInformation = true
                } label: {
                    Image(systemName: "info")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(headerTextColor)
                        .frame(width: 48, height: 48)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Get Info")

                Button {
                    Task { await playAll() }
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
                .disabled(vm.isPlayLoading || albums.isEmpty)

                Button {
                    HapticFeedback.light.trigger()
                    Task {
                        if isArtistFavorite {
                            await container?.toastService.perform { try await container?.favoritesService.unstar(itemType: .artist, itemId: artist.id) }
                        } else {
                            await container?.toastService.perform { try await container?.favoritesService.star(itemType: .artist, itemId: artist.id) }
                        }
                    }
                } label: {
                    Image(systemName: isArtistFavorite ? "star.fill" : "star")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(isArtistFavorite ? .white : headerTextColor)
                        .frame(width: 48, height: 48)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!isOnline)
            }
        }
    }

    private var canStartArtistAutomix: Bool {
        isOnline && viewModel?.artist?.album?.isEmpty == false && !isGeneratingMix
    }

    private func startArtistAutomix() {
        guard canStartArtistAutomix else { return }
        Task {
            isGeneratingMix = true
            await runInstantMix(from: .artist(id: artist.id), using: container)
            isGeneratingMix = false
        }
    }

    private func prepareArtistShare() {
        if let lastFmURL = viewModel?.lastFmURL {
            preparedArtistShare = .link(lastFmURL)
        } else {
            preparedArtistShare = .text(artist.name)
        }
    }

    @ViewBuilder
    private func artistShareSheet(for share: PreparedArtistShare) -> some View {
        switch share {
        case .link(let url):
            SystemShareSheet(item: url)
        case .text(let text):
            SystemShareSheet(item: text)
        }
    }

    private func loadDominantColor(coverArtId: String) async {
        guard let image = await container?.artworkImageCache.load(coverArtId: coverArtId) else { return }
        let color = colorExtractor.bottomStripColor(for: coverArtId, image: image)
        withAnimation(.easeIn(duration: 0.2)) {
            dominantColor = color
        }
    }

    // MARK: - Body sections

    /// The most recent release (max year) — featured + the hero fallback cover.
    private func latestRelease(_ vm: ArtistDetailViewModel) -> AlbumID3? {
        (vm.artist?.album ?? []).max(by: { ($0.year ?? 0) < ($1.year ?? 0) })
    }

    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.minidiscSectionTitle)
            .foregroundStyle(headerTextColor)
            .padding(.horizontal, MinidiscSpacing.l)
    }

    /// Featured (latest) release — a prominent card, Apple-Music style.
    private func featuredReleaseSection(_ album: AlbumID3) -> some View {
        VStack(alignment: .leading, spacing: MinidiscSpacing.s) {
            MinidiscCarouselHeader("Latest Release", showsChevron: false)
            NavigationLink(value: HomeDestination.album(album)) {
                HStack(spacing: MinidiscSpacing.m) {
                    CoverArtView(id: album.coverArt ?? album.id, size: 200)
                        .frame(width: 88, height: 88)
                        .clipShape(RoundedRectangle(cornerRadius: MinidiscCornerRadius.standard, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        if let year = album.year {
                            Text(verbatim: "\(year)")
                                .font(.minidiscCaption)
                                .foregroundStyle(headerSecondaryColor)
                        }
                        Text(album.name)
                            .font(.minidiscCellTitle)
                            .foregroundStyle(headerTextColor)
                            .lineLimit(2)
                        Text("\(album.songCount) songs")
                            .font(.minidiscCaption)
                            .foregroundStyle(headerSecondaryColor)
                    }
                    Spacer(minLength: 0)
                }
                .padding(MinidiscSpacing.m)
                .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: MinidiscCornerRadius.large, style: .continuous))
                // Make the WHOLE card (incl. the Spacer / background) tappable — a styled label in a plain
                // NavigationLink otherwise only registers taps on the opaque content (cover/text), not the gaps.
                .contentShape(RoundedRectangle(cornerRadius: MinidiscCornerRadius.large, style: .continuous))
                .padding(.horizontal, MinidiscSpacing.l)
            }
            .buttonStyle(.plain)
            .lazyCollectionContextMenu(
                itemType: .album,
                itemId: album.id,
                displayName: album.name,
                displaySubtitle: album.artist ?? "",
                coverArtId: album.coverArt ?? album.id,
                favoriteType: .album,
                songLoader: { await albumTracks(album) }
            )
        }
    }

    // MARK: - Liked songs

    /// The artist's starred tracks, gathered from every album. `vm.likedSongs` is the server snapshot taken
    /// when the screen loaded; `filteredByLocalStars` keeps it honest as stars change under it.
    private func likedSongs(_ vm: ArtistDetailViewModel) -> [DisplayableSong] {
        ArtistBestOf.filteredByLocalStars(vm.likedSongs, starredSongIds: Set(songFavorites.map(\.itemId)))
    }

    /// The "The best of <artist>" card, shown under the discography once the artist has enough liked tracks
    /// to make a playlist worth opening. Below that threshold `likedSongsSection` lists them inline instead.
    private func bestOfSection(_ songs: [DisplayableSong]) -> some View {
        VStack(alignment: .leading, spacing: MinidiscSpacing.s) {
            sectionHeader("Made For You")
            NavigationLink(value: HomeDestination.artistBestOf(
                artistId: artist.id,
                artistName: artist.name,
                coverArtId: viewModel?.artist?.coverArt ?? artist.coverArt
            )) {
                HStack(spacing: MinidiscSpacing.m) {
                    CoverArtView(id: heroCoverArtId, size: 200)
                        .frame(width: 88, height: 88)
                        .clipShape(RoundedRectangle(cornerRadius: MinidiscCornerRadius.standard, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Playlist")
                            .font(.minidiscCaption)
                            .foregroundStyle(headerSecondaryColor)
                        Text("The best of \(artist.name)")
                            .font(.minidiscCellTitle)
                            .foregroundStyle(headerTextColor)
                            .lineLimit(2)
                        Text("\(songs.count) songs")
                            .font(.minidiscCaption)
                            .foregroundStyle(headerSecondaryColor)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.minidiscCaption)
                        .foregroundStyle(headerSecondaryColor)
                }
                .padding(MinidiscSpacing.m)
                .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: MinidiscCornerRadius.large, style: .continuous))
                // Make the WHOLE card tappable, gaps included (see featuredReleaseSection).
                .contentShape(RoundedRectangle(cornerRadius: MinidiscCornerRadius.large, style: .continuous))
                .padding(.horizontal, MinidiscSpacing.l)
            }
            .buttonStyle(.plain)
        }
    }

    /// The handful of liked tracks an artist has before they earn a best-of playlist.
    private func likedSongsSection(_ songs: [DisplayableSong]) -> some View {
        VStack(alignment: .leading, spacing: MinidiscSpacing.s) {
            HStack(spacing: MinidiscSpacing.m) {
                sectionHeader("Liked Songs")
                Spacer()
                Button {
                    Task { await container?.toastService.perform { try await container?.playerService.play(tracks: songs.shuffled(), startIndex: 0) } }
                } label: {
                    Image(systemName: "shuffle")
                        .font(.minidiscSectionTitle)
                        .foregroundStyle(headerTextColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Shuffle liked songs")
                .padding(.trailing, MinidiscSpacing.l)
            }
            VStack(spacing: 0) {
                ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                    Button {
                        Task { await container?.toastService.perform { try await container?.playerService.play(tracks: songs, startIndex: index) } }
                    } label: {
                        SongRow(
                            song: song,
                            index: index + 1,
                            showCoverArt: true,
                            showArtist: false,
                            isFavorite: true,
                            titleColor: headerTextColor,
                            secondaryColor: headerSecondaryColor
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, MinidiscSpacing.l)
        }
    }

    private var likedSongsSkeleton: some View {
        VStack(alignment: .leading, spacing: MinidiscSpacing.s) {
            sectionHeader("Liked Songs")
            VStack(spacing: MinidiscSpacing.m) {
                ForEach(0..<3, id: \.self) { _ in
                    HStack(spacing: MinidiscSpacing.m) {
                        SkeletonBlock(width: 44, height: 44, cornerRadius: MinidiscCornerRadius.standard)
                        VStack(alignment: .leading, spacing: 6) {
                            SkeletonBlock(width: 180, height: 13, cornerRadius: 4)
                            SkeletonBlock(width: 120, height: 11, cornerRadius: 4)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, MinidiscSpacing.l)
        }
        .allowsHitTesting(false)
    }

    /// Loads an album's tracks only when a context-menu action needs a playable queue.
    private func albumTracks(_ album: AlbumID3) async -> [DisplayableSong] {
        guard let detail = try? await container?.libraryService.album(id: album.id) else { return [] }
        return detail.song?.map { DisplayableSong(from: $0) } ?? []
    }

    private func playAll() async {
        guard let c = container else { return }
        viewModel?.isPlayLoading = true
        defer { viewModel?.isPlayLoading = false }
        // Offline the catalogue fetch can't run — shuffle what's on disk instead.
        if let offline = viewModel?.offlineTracks, viewModel?.isOffline == true, !offline.isEmpty {
            await c.toastService.perform { try await c.playerService.play(tracks: offline.shuffled(), startIndex: 0) }
            return
        }
        do {
            let tracks = try await c.libraryService.fetchAllTracks(forArtistID: artist.id)
            try await c.playerService.play(tracks: tracks.shuffled(), startIndex: 0)
        } catch MinidiscError.artistTracksUnavailable {
            c.toastService.showError("Unable to load artist tracks. Please check your connection and try again.")
        } catch {
            c.toastService.showError("Playback failed. Please try again.")
        }
    }

    private var skeletonGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: MinidiscSpacing.l) {
                ForEach(0..<6, id: \.self) { _ in SkeletonAlbumCard() }
            }
            .padding(MinidiscSpacing.l)
        }
    }

}

// MARK: - Artist content shelves

private enum ArtistDetailMetrics {
    static let topSongArtwork: CGFloat = 44
    static let similarArtistArtwork: CGFloat = 104
}

private struct ArtistAlbumShelf: View {
    let title: LocalizedStringResource
    let albums: [AlbumID3]

    var body: some View {
        MinidiscShelf {
            MinidiscCarouselHeaderLink(title, itemCount: albums.count) {
                AlbumCarouselCollectionView(title, albums: albums)
            }
        } content: {
            ForEach(Array(albums.prefix(MinidiscCarouselMetrics.previewLimit))) { album in
                AlbumShelfCard(
                    album: album,
                    metadataSubtitle: album.year.map(String.init) ?? ""
                )
            }
        }
    }
}

private struct ArtistTopSongsSection: View {
    let artistName: String
    let songs: [DisplayableSong]
    let titleColor: Color
    let secondaryColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: MinidiscSpacing.s) {
            MinidiscCarouselHeaderLink(
                "Top Songs",
                itemCount: songs.count,
                visibleLimit: 5
            ) {
                ArtistTopSongsCollectionView(artistName: artistName, songs: songs)
            }
            ArtistTopSongsList(
                artistName: artistName,
                displayedSongs: Array(songs.prefix(5)),
                playbackSongs: songs,
                titleColor: titleColor,
                secondaryColor: secondaryColor
            )
            .padding(.horizontal, MinidiscSpacing.l)
        }
    }
}

private struct ArtistTopSongsSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: MinidiscSpacing.s) {
            MinidiscCarouselHeader("Top Songs", showsChevron: false)
            VStack(spacing: 0) {
                ForEach(0..<5, id: \.self) { _ in
                    HStack(spacing: MinidiscSpacing.s) {
                        SkeletonBlock(
                            width: ArtistDetailMetrics.topSongArtwork,
                            height: ArtistDetailMetrics.topSongArtwork,
                            cornerRadius: MinidiscCornerRadius.xs
                        )
                        VStack(alignment: .leading, spacing: 6) {
                            SkeletonBlock(width: 180, height: 14, cornerRadius: 4)
                            SkeletonBlock(width: 120, height: 11, cornerRadius: 4)
                        }
                        Spacer(minLength: 0)
                        SkeletonBlock(width: 28, height: 10, cornerRadius: 4)
                    }
                    .padding(.vertical, MinidiscSpacing.xs)
                }
            }
            .padding(.horizontal, MinidiscSpacing.l)
        }
        .allowsHitTesting(false)
    }
}

private struct ArtistTopSongAlbumDestination: Identifiable {
    let id: String
    let name: String
    let coverArtId: String?
}

private struct ArtistTopSongsList: View {
    let artistName: String
    let displayedSongs: [DisplayableSong]
    let playbackSongs: [DisplayableSong]
    var titleColor: Color = .primary
    var secondaryColor: Color = .secondary

    @Environment(PlaylistAddition.self) private var playlistAddition
    @Environment(\.appContainer) private var container
    @State private var selectedAlbum: ArtistTopSongAlbumDestination?
    @Query(filter: #Predicate<FavoriteRecord> { $0.itemType == "song" })
    private var songFavorites: [FavoriteRecord]

    private var favoriteSongIDs: Set<String> {
        Set(songFavorites.map(\.itemId))
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(displayedSongs.enumerated(), id: \.element.id) { index, song in
                VStack(spacing: 0) {
                    SongRow(
                        song: song,
                        index: index + 1,
                        showCoverArt: true,
                        showArtist: false,
                        secondaryText: song.albumName ?? artistName,
                        coverArtSize: ArtistDetailMetrics.topSongArtwork,
                        coverArtCornerRadius: MinidiscCornerRadius.xs,
                        primaryContentSpacing: MinidiscSpacing.m,
                        isFavorite: favoriteSongIDs.contains(song.id),
                        titleColor: titleColor,
                        secondaryColor: secondaryColor,
                        trailingAccessory: .menu,
                        onAddToPlaylist: playlistAddition.present,
                        onGoToAlbum: { presentAlbum(for: song) },
                        onTap: { play(song) }
                    )
                    .padding(.vertical, MinidiscSpacing.xs)

                    if song.id != displayedSongs.last?.id {
                        Divider()
                            .overlay(secondaryColor.opacity(0.26))
                            .padding(.leading, ArtistDetailMetrics.topSongArtwork + MinidiscSpacing.s)
                    }
                }
            }
        }
        .sheet(item: $selectedAlbum) { album in
            NavigationStack {
                AlbumDetailView(
                    albumId: album.id,
                    albumName: album.name,
                    coverArtId: album.coverArtId
                )
            }
        }
    }

    private func presentAlbum(for song: DisplayableSong) {
        guard let albumId = song.albumId,
              let albumName = song.albumName,
              !albumName.isEmpty else { return }
        selectedAlbum = ArtistTopSongAlbumDestination(
            id: albumId,
            name: albumName,
            coverArtId: song.coverArtId
        )
    }

    private func play(_ song: DisplayableSong) {
        guard let index = playbackSongs.firstIndex(where: { $0.id == song.id }) else { return }
        Task { await container?.toastService.perform { try await container?.playerService.play(tracks: playbackSongs, startIndex: index) } }
    }
}

private struct ArtistTopSongsCollectionView: View {
    let artistName: String
    let songs: [DisplayableSong]

    var body: some View {
        ScrollView {
            ArtistTopSongsList(
                artistName: artistName,
                displayedSongs: songs,
                playbackSongs: songs
            )
            .padding(MinidiscSpacing.l)
        }
        .minidiscContentWidth()
        .navigationTitle("Top Songs")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ArtistSimilarArtistsShelf: View {
    let recommendations: [SimilarArtistRecommendation]
    let imageURLs: [String: URL?]
    let isLoading: Bool
    let onOutOfLibraryTap: (SimilarArtistRecommendation) -> Void

    var body: some View {
        if isLoading {
            VStack(alignment: .leading, spacing: MinidiscSpacing.s) {
                MinidiscCarouselHeader("Similar Artists", showsChevron: false)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: MinidiscSpacing.m) {
                        ForEach(0..<6, id: \.self) { _ in
                            VStack(spacing: MinidiscSpacing.xs) {
                                SkeletonBlock(
                                    width: ArtistDetailMetrics.similarArtistArtwork,
                                    height: ArtistDetailMetrics.similarArtistArtwork,
                                    cornerRadius: ArtistDetailMetrics.similarArtistArtwork / 2
                                )
                                SkeletonBlock(width: 96, height: 11, cornerRadius: 4)
                            }
                            .frame(width: ArtistDetailMetrics.similarArtistArtwork)
                        }
                    }
                    .padding(.horizontal, MinidiscSpacing.l)
                }
            }
            .allowsHitTesting(false)
        } else {
            MinidiscShelf {
                MinidiscCarouselHeaderLink(
                    "Similar Artists",
                    itemCount: recommendations.count
                ) {
                    SimilarArtistsCollectionView(
                        recommendations: recommendations,
                        imageURLs: imageURLs
                    )
                }
            } content: {
                ForEach(Array(recommendations.prefix(MinidiscCarouselMetrics.previewLimit))) { recommendation in
                    ArtistRecommendationCard(
                        recommendation: recommendation,
                        imageURL: imageURLs[recommendation.id] ?? nil,
                        size: ArtistDetailMetrics.similarArtistArtwork,
                        onOutOfLibraryTap: { onOutOfLibraryTap(recommendation) }
                    )
                }
            }
        }
    }
}

private struct ArtistRecommendationCard: View {
    let recommendation: SimilarArtistRecommendation
    let imageURL: URL?
    let size: CGFloat
    let onOutOfLibraryTap: () -> Void

    var body: some View {
        VStack {
            if recommendation.inLibrary {
                NavigationLink(value: HomeDestination.artist(
                    ArtistID3(
                        id: recommendation.id,
                        name: recommendation.name,
                        coverArt: recommendation.coverArt
                    )
                )) {
                    SimilarArtistCell(
                        recommendation: recommendation,
                        externalImageURL: imageURL,
                        size: size,
                        onOutOfLibraryTap: onOutOfLibraryTap
                    )
                }
                .buttonStyle(.plain)
            } else {
                SimilarArtistCell(
                    recommendation: recommendation,
                    externalImageURL: imageURL,
                    size: size,
                    onOutOfLibraryTap: onOutOfLibraryTap
                )
            }
        }
    }
}

private struct SimilarArtistsCollectionView: View {
    let recommendations: [SimilarArtistRecommendation]
    let imageURLs: [String: URL?]

    @Environment(\.appContainer) private var container
    @State private var selectedArtist: SimilarArtistRecommendation?

    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 170), spacing: MinidiscSpacing.l)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .center, spacing: MinidiscSpacing.l) {
                ForEach(recommendations) { recommendation in
                    ArtistRecommendationCard(
                        recommendation: recommendation,
                        imageURL: imageURLs[recommendation.id] ?? nil,
                        size: 132,
                        onOutOfLibraryTap: { selectedArtist = recommendation }
                    )
                }
            }
            .padding(MinidiscSpacing.l)
        }
        .minidiscContentWidth()
        .navigationTitle("Similar Artists")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedArtist) { recommendation in
            OutOfLibraryArtistSheet(
                artist: recommendation,
                imageURL: imageURLs[recommendation.id] ?? nil,
                providers: container?.externalProvidersStore.load() ?? []
            )
        }
    }
}

// MARK: - Out-of-library artist sheet

struct OutOfLibraryArtistSheet: View {
    let artist: SimilarArtistRecommendation
    let imageURL: URL?
    let providers: [ExternalReleaseProvider]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: MinidiscSpacing.l) {
                    ExternalCoverView(url: imageURL) {
                        ArtistPlaceholderView(name: artist.name, size: 120)
                    }
                    .frame(width: 120, height: 120)
                    .clipShape(Circle())
                    .padding(.top, MinidiscSpacing.l)

                    VStack(spacing: MinidiscSpacing.xs) {
                        Text(artist.name)
                            .font(.title2.bold())
                            .multilineTextAlignment(.center)

                        Text("Not in your library")
                            .font(.minidiscCaption)
                            .foregroundStyle(.secondary)
                    }

                    externalLinksSection
                }
                .padding(MinidiscSpacing.l)
            }
            .navigationTitle(artist.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var externalLinksSection: some View {
        VStack(spacing: MinidiscSpacing.s) {
            if !providers.isEmpty {
                ForEach(providers) { provider in
                    if let url = provider.buildURL(artistName: artist.name, albumTitle: "") {
                        externalLinkButton(title: "View on \(provider.name)", url: url, secondary: false)
                    }
                }
            }

            if let mbid = artist.mbid {
                if let lbURL = URL(string: "https://listenbrainz.org/artist/\(mbid)/") {
                    externalLinkButton(
                        title: "View on ListenBrainz",
                        url: lbURL,
                        secondary: !providers.isEmpty
                    )
                }
                if let mbURL = URL(string: "https://musicbrainz.org/artist/\(mbid)") {
                    externalLinkButton(
                        title: "View on MusicBrainz",
                        url: mbURL,
                        secondary: !providers.isEmpty
                    )
                }
            }
        }
        .padding(.horizontal, MinidiscSpacing.l)
    }

    private func externalLinkButton(title: LocalizedStringKey, url: URL, secondary: Bool) -> some View {
        Button {
            ExternalLinkOpener.open(url)
        } label: {
            HStack {
                Text(title)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
            }
            .font(.minidiscCellTitle)
            .padding(MinidiscSpacing.m)
            .frame(maxWidth: .infinity)
            .background(secondary
                ? Color.secondary.opacity(0.08)
                : Color.minidiscAccent.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: MinidiscCornerRadius.standard, style: .continuous))
            .foregroundStyle(secondary ? Color.secondary : Color.minidiscAccent)
        }
        .buttonStyle(.plain)
    }
}
