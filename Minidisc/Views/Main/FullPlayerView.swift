import SwiftUI
import SwiftData
import SwiftSonic
import OSLog

import AVKit

private enum PlayerSurface { case player, queue }

private struct PlayerThemeKey: Equatable {
    let coverId: String?
    let override: Color?
}

private struct LyricsLoadKey: Equatable {
    let trackID: String?
    let source: LyricsSource
    let isRequested: Bool
}

private struct FullPlayerBackground: View {
    let dominantColor: Color

    var body: some View {
        LinearGradient(
            stops: gradientStops,
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    private var gradientStops: [Gradient.Stop] {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        let resolvedColor = UIColor(dominantColor)
        guard resolvedColor.getHue(
            &hue,
            saturation: &saturation,
            brightness: &brightness,
            alpha: &alpha
        ) else {
            return [
                .init(color: .black, location: 0),
                .init(color: .black, location: 1),
            ]
        }

        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        let perceivedLuminance: Double
        if resolvedColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            perceivedLuminance = 0.299 * Double(red) + 0.587 * Double(green) + 0.114 * Double(blue)
        } else {
            perceivedLuminance = 0.5
        }

        let contrastDimming = min(max((perceivedLuminance - 0.48) * 0.56, 0), 0.28)
        // Whole-image averages lose chroma. Scaling the existing saturation keeps neutral artwork neutral.
        let isChromatic = saturation >= 0.08
        let baseBrightness = isChromatic ? max(Double(brightness), 0.30) : Double(brightness)

        func color(saturationMultiplier: Double, dimming: Double) -> Color {
            Color(
                hue: Double(hue),
                saturation: isChromatic ? min(Double(saturation) * saturationMultiplier, 1) : Double(saturation),
                brightness: baseBrightness * (1 - min(max(dimming, 0), 0.82))
            )
        }

        return [
            .init(
                color: color(saturationMultiplier: 1.6, dimming: 0.18 + contrastDimming),
                location: 0
            ),
            .init(
                color: color(saturationMultiplier: 1.85, dimming: 0.28 + contrastDimming),
                location: 0.48
            ),
            .init(
                color: color(saturationMultiplier: 1.85, dimming: 0.46 + contrastDimming * 0.75),
                location: 1
            ),
        ]
    }
}

struct FullPlayerView: View {
    @Environment(\.appContainer) private var container
    @Environment(DominantColorExtractor.self) private var colorExtractor
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss

    @State private var vm = FullPlayerViewModel()
    @State private var playlistAddition = PlaylistAddition()
    @State private var showLyrics = false
    @State private var surface: PlayerSurface = .player
    @State private var lyricsViewModel: LyricsViewModel?
    @State private var trackSwipe = TrackSwipeInteraction()
    @Namespace private var morphNS

    // MARK: - Player layout

    private static let playerCoverHPadding: CGFloat = MinidiscSpacing.xxl
    private static let playerHorizontalPadding: CGFloat = MinidiscSpacing.xxxl
    private static let playerTopGap: CGFloat = 36
    private static let playerCoverToTitleGap: CGFloat = MinidiscSpacing.xl
    private static let playerControlsSpacing: CGFloat = MinidiscSpacing.xl

    var body: some View {
        @Bindable var playlistAddition = playlistAddition

        if let playerState = container?.playerState {
            let lyricsSource = container?.lyricsSettings.source ?? .automatic
            let lyricsLoadKey = LyricsLoadKey(
                trackID: playerState.currentTrack?.id,
                source: lyricsSource,
                isRequested: showLyrics
            )
            let themeCoverId: String? = playerState.isLiveStream
                ? playerState.currentRadio?.coverArt
                : (playerState.currentTrack?.coverArtId ?? playerState.currentTrack?.id)
            content(playerState)
                .interactiveDismissDisabled(trackSwipe.isHorizontalDragActive)
                .task(id: PlayerThemeKey(coverId: themeCoverId, override: colorExtractor.colorOverride(for: themeCoverId ?? ""))) {
                    await vm.updateColors(for: themeCoverId, colorExtractor: colorExtractor, container: container)
                }
                .task(id: lyricsLoadKey) {
                    guard showLyrics,
                          let track = playerState.currentTrack,
                          let serverId = container?.serverState.activeServer?.id,
                          let lyricsService = container?.lyricsService,
                          let playerService = container?.playerService else {
                        lyricsViewModel = nil
                        return
                    }
                    let newVM = LyricsViewModel(
                        track: track,
                        serverId: serverId,
                        source: lyricsSource,
                        lyricsService: lyricsService,
                        playerService: playerService,
                        playerState: playerState
                    )
                    lyricsViewModel = newVM
                    await newVM.load()
                }
                .sheet(item: $playlistAddition.selectedSong) { song in
                    AddToPlaylistSheet(song: song)
                }
                .environment(playlistAddition)
        }
    }

    @ViewBuilder
    private func content(_ playerState: PlayerState) -> some View {
        let coverArtId = playerState.isLiveStream
            ? (playerState.currentRadio?.coverArt ?? "")
            : (playerState.currentTrack?.coverArtId ?? playerState.currentTrack?.id ?? "")
        // Use the memoized color on the first frame while the view model catches up.
        let dominant = colorExtractor.cachedColor(for: coverArtId) ?? vm.dominantColor
        let showingQueue = isQueueVisible(playerState)

        surfaceStack(playerState, coverArtId: coverArtId, showingQueue: showingQueue)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .minidiscContentWidth()
            .environment(\.colorScheme, .dark)
            .environment(\.minidiscPlayingAccent, MinidiscColors.accent)
        .background {
            FullPlayerBackground(dominantColor: dominant)
        }
    }

    @ViewBuilder
    private func surfaceStack(
        _ playerState: PlayerState,
        coverArtId: String,
        showingQueue: Bool
    ) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                flowGap((showLyrics || showingQueue) ? 44 : Self.playerTopGap)

                ZStack {
                    if showLyrics, let lyricsVM = lyricsViewModel {
                        LyricsView(viewModel: lyricsVM)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 20)
                            .mask(
                                LinearGradient(
                                    stops: [
                                        .init(color: .clear, location: 0),
                                        .init(color: .black, location: 0.1),
                                        .init(color: .black, location: 0.8),
                                        .init(color: .clear, location: 1)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .transition(.opacity)
                    } else if showingQueue {
                        flowingQueueContent(playerState)
                            .transition(.opacity)
                    }

                    // Keep the cover mounted across player and queue for matched geometry.
                    if !showLyrics {
                        flowingCover(playerState, coverArtId: coverArtId, isSource: !showingQueue)
                            .allowsHitTesting(!showingQueue)
                            .padding(.horizontal, showingQueue ? 0 : Self.playerCoverHPadding)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                flowGap(Self.playerCoverToTitleGap)

                if !showingQueue {
                    TrackInfoSection(
                        playerState: playerState,
                        container: container,
                        contentColor: vm.contentColor,
                        secondaryContentColor: vm.secondaryContentColor,
                        trackSwipe: trackSwipe
                    )
                    .padding(.horizontal, Self.playerHorizontalPadding)
                }

                if !playerState.isLiveStream {
                    ScrubberView(
                        playerState: playerState,
                        playerService: container?.playerService,
                        contentColor: vm.contentColor,
                        secondaryContentColor: vm.secondaryContentColor
                    )
                    .padding(.horizontal, Self.playerHorizontalPadding)
                    .padding(.top, MinidiscSpacing.m)
                    .disabled(!playerState.isPlaybackAvailable)
                    .opacity(playerState.isPlaybackAvailable ? 1.0 : 0.4)
                }

                PlaybackControlsView(
                    playerState: playerState,
                    playerService: container?.playerService,
                    isPlaybackAvailable: playerState.isPlaybackAvailable,
                    keepsPauseIcon: trackSwipe.keepsPauseIcon,
                    contentColor: vm.contentColor
                )
                .padding(.top, Self.playerControlsSpacing)

                if dynamicTypeSize < .accessibility1 {
                    VolumeSection(contentColor: vm.contentColor, secondaryContentColor: vm.secondaryContentColor)
                        .padding(.horizontal, Self.playerHorizontalPadding)
                        .padding(.top, Self.playerControlsSpacing)
                }

                flowGap((showLyrics || showingQueue) ? MinidiscSpacing.xs : 40)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.smooth(duration: 0.3), value: showLyrics)
            .animation(.smooth(duration: 0.3), value: surface)

            BottomToolbar(
                showLyrics: $showLyrics,
                surface: $surface,
                isLiveStream: playerState.isLiveStream,
                secondaryContentColor: vm.secondaryContentColor,
                accentColor: MinidiscColors.accent,
                playerState: playerState
            )
            .padding(.top, MinidiscSpacing.s)
            .padding(.bottom, MinidiscSpacing.l)
        }
        .overlay(alignment: .top) {
            topBar
        }
    }

    private func flowGap(_ floor: CGFloat) -> some View {
        Color.clear.frame(minHeight: floor, maxHeight: floor)
    }

    private func flowingCover(_ playerState: PlayerState, coverArtId: String, isSource: Bool) -> some View {
        GeometryReader { geo in
            let artworkSide = min(geo.size.width, geo.size.height)
            CoverArtView(id: coverArtId, size: 1000)
                .frame(
                    width: isSource ? artworkSide : nil,
                    height: isSource ? artworkSide : nil
                )
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: isSource ? MinidiscCornerRadius.large : MinidiscCornerRadius.standard,
                        style: .continuous
                    )
                )
                .drawingGroup()
                .shadow(
                    color: isSource ? Color.black.opacity(0.28) : .clear,
                    radius: 18,
                    y: 10
                )
                .matchedGeometryEffect(id: "queueCover", in: morphNS, isSource: isSource)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .trackSwipeGesture(
                    interaction: trackSwipe,
                    playerState: playerState,
                    playerService: container?.playerService,
                    reduceMotion: reduceMotion,
                    isEnabled: isSource && playerState.isPlaybackAvailable && !playerState.isLiveStream
                )
        }
    }

    private func flowingQueueContent(_ playerState: PlayerState) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: MinidiscSpacing.m) {
                // Invisible endpoint for the cover's matched-geometry transition.
                Color.clear
                    .frame(width: 56, height: 56)
                    .matchedGeometryEffect(id: "queueCover", in: morphNS, isSource: true)

                TrackInfoSection(
                    playerState: playerState,
                    container: container,
                    contentColor: vm.contentColor,
                    secondaryContentColor: vm.secondaryContentColor,
                    compact: true
                )
            }
            .padding(.horizontal, MinidiscSpacing.l)
            .padding(.top, MinidiscSpacing.s)

            queuePills(playerState)
                .padding(.horizontal, MinidiscSpacing.l)
                .padding(.vertical, MinidiscSpacing.m)

            upNextHeader(playerState)
                .padding(.horizontal, MinidiscSpacing.l)
                .padding(.bottom, MinidiscSpacing.xs)

            InlineQueueList(
                playerState: playerState,
                contentColor: vm.contentColor,
                secondaryContentColor: vm.secondaryContentColor,
                loadArtwork: true
            )
            // The system reorder grip follows the cover luminance.
            .environment(\.colorScheme, .dark)
            .frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)

            queueStatusLine(playerState)
                .padding(.horizontal, MinidiscSpacing.l)
                .padding(.vertical, MinidiscSpacing.s)
        }
    }

    // MARK: - Surfaces

    private func isQueueVisible(_ playerState: PlayerState) -> Bool {
        surface == .queue && !playerState.isLiveStream
    }

    private func queuePills(_ playerState: PlayerState) -> some View {
        HStack(spacing: MinidiscSpacing.s) {
            queuePill(systemImage: "shuffle", isActive: playerState.isShuffled,
                      label: playerState.isShuffled ? "Shuffle On" : "Shuffle Off") {
                Task { await container?.playerService.toggleShuffle() }
            }
            queuePill(systemImage: playerState.repeatMode.systemImage, isActive: playerState.repeatMode != .off,
                      label: "Repeat") {
                Task { await container?.playerService.setRepeatMode(playerState.repeatMode.next) }
            }
            queuePill(systemImage: "infinity", isActive: playerState.isAutoExtendEnabled,
                      label: "Auto-extend with Smart Shuffle") {
                Task { await container?.playerService.setAutoExtendEnabled(!playerState.isAutoExtendEnabled) }
            }
        }
    }

    private func queuePill(systemImage: String, isActive: Bool, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        // The fixed active color keeps 4.7:1 contrast with its white glyph.
        return Button {
            HapticFeedback.light.trigger()
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(isActive ? Color.white : vm.secondaryContentColor)
                .frame(height: 24)
                .frame(maxWidth: .infinity)
                .padding(.vertical, MinidiscSpacing.s)
                .background {
                    Capsule().fill(isActive ? MinidiscColors.AccentRamp.v500 : vm.contentColor.opacity(0.12))
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func upNextHeader(_ playerState: PlayerState) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Up Next")
                .font(.minidiscSectionTitle)
                .foregroundStyle(vm.contentColor)
            if let album = playerState.currentTrack?.albumName, !album.isEmpty {
                Text(album)
                    .font(.minidiscCaption)
                    .foregroundStyle(vm.secondaryContentColor)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func queueStatusLine(_ playerState: PlayerState) -> some View {
        let upNextCount = max(playerState.queue.count - playerState.currentIndex - 1, 0)
        var bits: [String] = ["\(upNextCount) up next"]
        if playerState.repeatMode == .all {
            bits.append("Repeating all")
        } else if playerState.repeatMode == .one {
            bits.append("Repeating one")
        }
        if playerState.isShuffled { bits.append("Shuffled") }
        if playerState.isAutoExtendEnabled { bits.append("Auto-extend on") }
        return Text(bits.joined(separator: " · "))
            .font(.minidiscCaption)
            .foregroundStyle(vm.secondaryContentColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lineLimit(1)
    }

    private var topBar: some View {
        Button {
            dismiss()
        } label: {
            Capsule()
                .fill(vm.contentColor.opacity(0.4))
                .frame(width: 60, height: 5)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .top)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close player")
    }

}

// MARK: - Track info section (own @Query for reactive favorite state)

private struct TrackInfoSection: View {
    let playerState: PlayerState
    let container: AppContainer?
    let contentColor: Color
    let secondaryContentColor: Color
    var compact: Bool = false
    var trackSwipe: TrackSwipeInteraction?

    @Query private var favoriteMatches: [FavoriteRecord]
    @Environment(PlaylistAddition.self) private var playlistAddition
    @State private var showAlbumSheet = false
    @State private var shareRequest: DisplayableSong?
    @State private var preparedShare: PreparedTrackShare?
    @State private var trackInformation: DisplayableSong?

    init(
        playerState: PlayerState,
        container: AppContainer?,
        contentColor: Color,
        secondaryContentColor: Color,
        compact: Bool = false,
        trackSwipe: TrackSwipeInteraction? = nil
    ) {
        self.playerState = playerState
        self.container = container
        self.contentColor = contentColor
        self.secondaryContentColor = secondaryContentColor
        self.compact = compact
        self.trackSwipe = trackSwipe
        let cid = "song:\(playerState.currentTrack?.id ?? "")"
        _favoriteMatches = Query(filter: #Predicate<FavoriteRecord> { $0.id == cid })
    }

    private var isFavorite: Bool { !favoriteMatches.isEmpty }
    private var isOnline: Bool { container?.serverState.isOnline == true }

    var body: some View {
        HStack(alignment: .top, spacing: MinidiscSpacing.m) {
            trackMetadata
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())

            HStack(spacing: MinidiscSpacing.s) {
                if !playerState.isLiveStream {
                    Button {
                        toggleFavorite()
                    } label: {
                        Image(systemName: isFavorite ? "star.fill" : "star")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(contentColor)
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!isOnline || playerState.currentTrack == nil)
                    .accessibilityLabel(isFavorite ? "Remove from Favorites" : "Add to Favorites")
                }

                Menu {
                    if !playerState.isLiveStream {
                        ControlGroup {
                            if let track = playerState.currentTrack {
                                Button {
                                    shareRequest = track
                                } label: {
                                    Label("Share", systemImage: "square.and.arrow.up.fill")
                                }
                                .disabled(shareRequest != nil)
                            }

                            if isFavorite {
                                Button("Undo", systemImage: "star.slash.fill") {
                                    toggleFavorite()
                                }
                                .disabled(!isOnline || playerState.currentTrack == nil)
                            } else {
                                Button("Favorite", systemImage: "star.fill") {
                                    toggleFavorite()
                                }
                                .disabled(!isOnline || playerState.currentTrack == nil)
                            }
                        }

                        Divider()
                        Button {
                            guard playerState.currentTrack?.albumId != nil else { return }
                            showAlbumSheet = true
                        } label: {
                            Label("Go to Album", systemImage: "music.note.square.stack")
                            if let albumName = playerState.currentTrack?.albumName, !albumName.isEmpty {
                                Text(albumName)
                            }
                        }
                        .disabled(playerState.currentTrack?.albumId == nil || !isOnline)
                        Button {
                            goToArtist()
                        } label: {
                            Label("Go to Artist", systemImage: "music.mic")
                            if let artist = playerState.currentTrack?.artist, !artist.isEmpty {
                                Text(artist)
                            }
                        }
                        .disabled(playerState.currentTrack?.artist == nil || !isOnline)
                        Button("Get Info", systemImage: "info.circle") {
                            trackInformation = playerState.currentTrack
                        }
                        .disabled(playerState.currentTrack == nil)
                        Divider()
                        Button("Add to Playlist...", systemImage: "music.note.list") {
                            if let track = playerState.currentTrack {
                                playlistAddition.present(track)
                            }
                        }
                        .disabled(!isOnline || playerState.currentTrack == nil)
                        Divider()
                        Button("Instant Mix", systemImage: instantMixSymbol) {
                            guard let track = playerState.currentTrack else { return }
                            startInstantMix(from: .song(id: track.id), using: container, startingWith: track)
                        }
                        .disabled(!isOnline || playerState.currentTrack == nil)
                        Divider()
                    }
                    Button {
                        Task { await triggerSmartShuffle() }
                    } label: {
                        Label("Smart Shuffle", systemImage: "shuffle.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(contentColor)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .menuOrder(.fixed)
                .buttonStyle(.plain)
                .tint(.primary)
                .accessibilityLabel("More options")
            }
        }
        .sheet(isPresented: $showAlbumSheet) {
            if let track = playerState.currentTrack,
               let albumId = track.albumId,
               let albumName = track.albumName {
                NavigationStack {
                    AlbumDetailView(albumId: albumId, albumName: albumName, coverArtId: track.coverArtId)
                }
            }
        }
        .sheet(item: $preparedShare) { share in
            shareSheet(for: share)
        }
        .sheet(item: $trackInformation) { track in
            TrackInformationSheet(track: track)
        }
        .task(id: shareRequest?.id) {
            await prepareRequestedShare()
        }
    }

    @ViewBuilder
    private var trackMetadata: some View {
        if !compact,
           !playerState.isLiveStream,
           playerState.isPlaybackAvailable,
           let trackSwipe {
            SwipeableTrackMetadata(
                playerState: playerState,
                playerService: container?.playerService,
                interaction: trackSwipe
            ) { song, isCurrent in
                metadata(for: song, isCurrent: isCurrent)
            }
        } else {
            metadata(for: playerState.currentTrack, isCurrent: true)
        }
    }

    private func metadata(for song: DisplayableSong?, isCurrent: Bool) -> some View {
        VStack(alignment: .leading, spacing: MinidiscSpacing.xs) {
            metadataTitle(
                playerState.isLiveStream ? (playerState.currentRadio?.name ?? "") : (song?.title ?? ""),
                usesMarquee: isCurrent && !compact && !playerState.isLiveStream
            )

            if isCurrent, let status = playerState.playbackStatusMessage {
                Text(status)
                    .font(.callout)
                    .foregroundStyle(secondaryContentColor)
                    .lineLimit(2)
            } else if playerState.isLiveStream {
                Text("Live Radio")
                    .font(.subheadline)
                    .foregroundStyle(secondaryContentColor)
                    .lineLimit(1)
            } else {
                metadataSubtitle(for: song, isCurrent: isCurrent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func metadataTitle(_ title: String, usesMarquee: Bool) -> some View {
        if usesMarquee {
            MarqueeTrackMetadataText(
                text: title,
                font: .title2,
                weight: .bold,
                color: contentColor
            )
        } else {
            Text(title)
                .font(compact ? .minidiscSectionTitle : .title2)
                .fontWeight(compact ? .semibold : .bold)
                .foregroundStyle(contentColor)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    @ViewBuilder
    private func metadataSubtitle(for song: DisplayableSong?, isCurrent: Bool) -> some View {
        if let artist = song?.artist {
            if isCurrent {
                Button {
                    goToArtist()
                } label: {
                    artistLabel(artist, usesMarquee: !compact)
                }
                .buttonStyle(.plain)
                .disabled(!isOnline)
            } else {
                artistLabel(artist, usesMarquee: false)
            }
        }
    }

    @ViewBuilder
    private func artistLabel(_ artist: String, usesMarquee: Bool) -> some View {
        if usesMarquee {
            MarqueeTrackMetadataText(
                text: artist,
                font: .title3,
                weight: .regular,
                color: secondaryContentColor
            )
        } else {
            Text(artist)
                .font(compact ? .subheadline : .title3)
                .foregroundStyle(secondaryContentColor)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func prepareRequestedShare() async {
        guard let track = shareRequest else { return }
        let share = await container?.trackSharingService.prepareShare(
            for: track,
            serverIsReachable: isOnline
        )
        guard !Task.isCancelled, shareRequest?.id == track.id else { return }
        shareRequest = nil
        preparedShare = share
    }

    @ViewBuilder
    private func shareSheet(for share: PreparedTrackShare) -> some View {
        switch share {
        case .publicLink(let url):
            SystemShareSheet(item: url)
        case .metadata(let text):
            SystemShareSheet(item: text)
        }
    }

    private func toggleFavorite() {
        guard let songId = playerState.currentTrack?.id, !songId.isEmpty else { return }
        HapticFeedback.light.trigger()
        let wasFavorite = isFavorite
        Task {
            if wasFavorite {
                await container?.toastService.perform { try await container?.favoritesService.unstar(itemType: .song, itemId: songId) }
            } else {
                await container?.toastService.perform { try await container?.favoritesService.star(itemType: .song, itemId: songId) }
            }
        }
    }

    /// Uses a name search only when the track has no artist id.
    private func goToArtist() {
        guard let track = playerState.currentTrack else { return }
        if track.artistId != nil {
            postNavigateToArtist(track: track)
            return
        }
        guard let name = track.artist else { return }
        Task {
            guard let c = container,
                  let result = try? await c.libraryService.search(name),
                  let found = result.artist?.first else { return }
            postNavigateToArtist(artistId: found.id, artistName: found.name, coverArtId: found.coverArt)
        }
    }

    private func triggerSmartShuffle() async {
        guard let container else { return }
        do {
            try await container.playerService.playSmartShuffle()
        } catch {
            container.toastService.showError(smartShuffleErrorMessage(from: error))
        }
    }

    private func smartShuffleErrorMessage(from error: Error) -> String {
        if case MinidiscError.smartShuffleEmpty = error {
            return "Smart Shuffle unavailable — try playing some tracks first or download more music for offline use."
        }
        return "Smart Shuffle failed. Please try again."
    }
}

// MARK: - Scrubber

private struct ScrubberView: View {
    let playerState: PlayerState
    let playerService: (any PlayerServiceProtocol)?
    let contentColor: Color
    let secondaryContentColor: Color

    @State private var isDragging = false
    @State private var isSeeking = false
    @State private var displayPosition: TimeInterval = 0

    // Fall back to metadata until AVPlayer reports a duration.
    private var effectiveDuration: TimeInterval {
        playerState.duration > 0 ? playerState.duration : (playerState.currentTrack?.duration ?? 0)
    }

    // Keep the requested position visible until AVPlayer confirms the seek.
    private var positionBinding: Binding<TimeInterval> {
        Binding(
            get: { (isDragging || isSeeking) ? displayPosition : playerState.position },
            set: { newValue in displayPosition = newValue }
        )
    }

    var body: some View {
        VStack(spacing: MinidiscSpacing.xs) {
            ProgressSlider(
                value: positionBinding,
                total: effectiveDuration,
                onEditingChanged: { editing in
                    isDragging = editing
                    if !editing {
                        isSeeking = true
                        let target = displayPosition
                        Task {
                            defer { isSeeking = false }
                            await playerService?.seek(to: target)
                        }
                    }
                },
                trackColor: contentColor.opacity(0.2),
                fillColor: contentColor.opacity(0.95),
                isInteracting: isDragging || isSeeking
            )

            ScrubberTimeLabels(
                playerState: playerState,
                effectiveDuration: effectiveDuration,
                overridePosition: (isDragging || isSeeking) ? displayPosition : nil,
                color: secondaryContentColor
            )
        }
    }
}

/// Isolates periodic position updates from the slider's drag state.
private struct ScrubberTimeLabels: View {
    let playerState: PlayerState
    let effectiveDuration: TimeInterval
    let overridePosition: TimeInterval?
    let color: Color

    var body: some View {
        let shown = overridePosition ?? playerState.position
        HStack {
            Text(Duration.seconds(shown).formatted(.time(pattern: .minuteSecond)))
                .font(.minidiscCaption)
                .foregroundStyle(color)
                .monospacedDigit()
            Spacer()
            Text(
                verbatim: "-\(Duration.seconds(max(effectiveDuration - shown, 0)).formatted(.time(pattern: .minuteSecond)))"
            )
                .font(.minidiscCaption)
                .foregroundStyle(color)
                .monospacedDigit()
        }
    }
}

struct ProgressSlider: View {
    @Binding var value: TimeInterval
    let total: TimeInterval
    let onEditingChanged: (Bool) -> Void
    var trackColor: Color = Color.white.opacity(0.2)
    var fillColor: Color = Color.white.opacity(0.95)
    var height: CGFloat = 32
    var trackHeight: CGFloat = 5
    var isInteracting: Bool = false

    @State private var isDragging = false
    @State private var dragValue: TimeInterval?

    var body: some View {
        GeometryReader { geo in
            let trackW = geo.size.width

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(trackColor)

                Capsule()
                    .fill(fillColor)
                    .frame(width: progressWidth(in: trackW))
                    .animation(nil, value: value)
            }
            .frame(height: isDragging ? 12 : trackHeight)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isDragging)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        // Avoid propagating NaN before the track has a measured width.
                        guard trackW > 0, total > 0, total.isFinite else { return }
                        if !isDragging {
                            isDragging = true
                            onEditingChanged(true)
                            HapticFeedback.light.trigger()
                        }
                        let ratio = gesture.location.x / trackW
                        let clampedRatio = max(0, min(1, ratio))
                        dragValue = total * clampedRatio
                        value = dragValue ?? value
                    }
                    .onEnded { _ in
                        guard total > 0, total.isFinite else { return }
                        isDragging = false
                        dragValue = nil
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: height)
        .accessibilityLabel("Playback position")
        .accessibilityValue(Duration.seconds(value).formatted(.time(pattern: .minuteSecond)))
        .accessibilityAdjustableAction { direction in
            let step = total * 0.05
            switch direction {
            case .increment:
                value = min(value + step, total)
                onEditingChanged(false)
            case .decrement:
                value = max(value - step, 0)
                onEditingChanged(false)
            @unknown default: break
            }
        }
    }

    private func progressWidth(in totalWidth: CGFloat) -> CGFloat {
        guard total > 0 else { return 0 }
        let displayedValue = dragValue ?? value
        return min(totalWidth, max(0, (CGFloat(displayedValue) / CGFloat(total)) * totalWidth))
    }
}

// MARK: - Playback controls

private struct PlaybackControlsView: View {
    @Environment(\.appContainer) private var container
    let playerState: PlayerState
    let playerService: (any PlayerServiceProtocol)?
    var isPlaybackAvailable: Bool = true
    var keepsPauseIcon: Bool = false
    let contentColor: Color

    var body: some View {
        let showsPause = keepsPauseIcon || playerState.wantsPlayback

        HStack(spacing: MinidiscSpacing.xxxxl) {
            if !playerState.isLiveStream {
                Button {
                    HapticFeedback.light.trigger()
                    Task { await container?.toastService.perform { try await playerService?.skipToPrevious() } }
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.title)
                        .foregroundStyle(contentColor)
                        .frame(width: 56, height: 56)
                }
                .disabled(playerState.queue.isEmpty)
                .accessibilityLabel("Skip to previous")
            }

            Button {
                HapticFeedback.medium.trigger()
                Task {
                    await playerService?.togglePlayPause()
                }
            } label: {
                Image(systemName: showsPause ? "pause.fill" : "play.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(isPlaybackAvailable ? contentColor : contentColor.opacity(0.4))
                    .frame(width: 80, height: 80)
            }
            .disabled(!isPlaybackAvailable)
            .accessibilityLabel(showsPause ? "Pause" : "Play")
            .accessibilityValue(playerState.playbackStatusMessage ?? "")

            if !playerState.isLiveStream {
                Button {
                    HapticFeedback.light.trigger()
                    Task { await container?.toastService.perform { try await playerService?.skipToNext() } }
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.title)
                        .foregroundStyle(contentColor)
                        .frame(width: 56, height: 56)
                }
                .disabled(playerState.queue.isEmpty)
                .accessibilityLabel("Skip to next")
            }
        }
    }
}

// MARK: - Bottom toolbar

private struct BottomToolbar: View {
    @Binding var showLyrics: Bool
    @Binding var surface: PlayerSurface
    let isLiveStream: Bool
    let secondaryContentColor: Color
    let accentColor: Color
    let playerState: PlayerState

    var body: some View {
        HStack(spacing: MinidiscSpacing.xxxxl) {
            if !isLiveStream {
                Button {
                    if surface == .queue { surface = .player }
                    withAnimation(.smooth(duration: 0.3)) { showLyrics.toggle() }
                } label: {
                    Image(systemName: "quote.bubble")
                        .font(.title3)
                        .foregroundStyle(showLyrics && surface == .player ? accentColor : secondaryContentColor)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Lyrics")
            }

            AirPlayRouteButton(tintColor: secondaryContentColor)
                .frame(width: 44, height: 44)

            if !isLiveStream {
                Button {
                    if surface == .queue {
                        surface = .player
                    } else {
                        surface = .queue
                        showLyrics = false
                    }
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.title3)
                        .foregroundStyle(surface == .queue ? accentColor : secondaryContentColor)
                        .overlay(alignment: .topTrailing) {
                            if let badge = playerState.queueModeBadge {
                                Image(systemName: badge)
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Color.minidiscAccent)
                                    .padding(2)
                                    .background(.background, in: Circle())
                                    .overlay(Circle().stroke(.background.opacity(0.5), lineWidth: 0.5))
                                    .offset(x: 6, y: -6)
                                    .transition(.scale.combined(with: .opacity))
                            }
                        }
                        .animation(.smooth(duration: 0.2), value: playerState.queueModeBadge)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Queue")
            }
        }
    }
}

private struct AirPlayRouteButton: UIViewRepresentable {
    var tintColor: Color = Color.white.opacity(0.7)

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.activeTintColor = UIColor(Color.minidiscAccent)
        view.tintColor = UIColor(tintColor)
        view.backgroundColor = .clear
        return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = UIColor(tintColor)
    }
}

// MARK: - Volume

private struct VolumeSection: View {
    let contentColor: Color
    let secondaryContentColor: Color

    var body: some View {
        HStack(spacing: MinidiscSpacing.m) {
            Image(systemName: "speaker.fill")
                .font(.caption)
                .foregroundStyle(secondaryContentColor)
                .frame(width: 20)
                .accessibilityHidden(true)

            SystemVolumeView(contentColor: contentColor)

            Image(systemName: "speaker.wave.3.fill")
                .font(.caption)
                .foregroundStyle(secondaryContentColor)
                .frame(width: 20)
                .accessibilityHidden(true)
        }
    }
}
