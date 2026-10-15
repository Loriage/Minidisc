import SwiftUI

nonisolated enum SongRowTrailingAccessory: Sendable, Equatable {
    /// Duration only (compact lists).
    case duration
    /// A heart toggle followed by the duration. Row actions live in the context menu and swipe actions.
    case favorite
}

/// Standard track cell for album and playlist detail screens.
///
/// - `showCoverArt`: show a 44pt thumbnail (useful in playlist context where tracks
///   may come from different albums). Default `false` for album tracks.
/// - `artistCredits`: when non-empty, replaces the artist line with tappable credits (album track lists
///   with featured artists). `onArtistsTap` receives the credits.
struct SongRow: View {
    let song: DisplayableSong
    let index: Int
    var showCoverArt: Bool = false
    var showArtist: Bool = true
    var secondaryText: String? = nil
    var coverArtSize: CGFloat = 44
    var coverArtCornerRadius: CGFloat = MinidiscCornerRadius.standard
    var primaryContentSpacing: CGFloat = MinidiscSpacing.s
    var isFavorite: Bool = false
    var titleColor: Color = .primary
    var secondaryColor: Color = .secondary
    var trailingAccessory: SongRowTrailingAccessory = .duration
    var rowAccessibilityIdentifier: String = ""
    let onDownload: (() -> Void)?
    let onRemoveDownload: (() -> Void)?
    var isDownloading: Bool = false
    var onRemoveFromPlaylist: (() -> Void)? = nil
    var onAddToPlaylist: ((DisplayableSong) -> Void)? = nil
    var onGoToAlbum: (() -> Void)? = nil
    var artistCredits: [ArtistCredit] = []
    var onArtistsTap: (([ArtistCredit]) -> Void)? = nil
    var onTap: (() -> Void)? = nil

    @Environment(\.appContainer) private var container
    @Environment(ArtworkImageCache.self) private var artworkImageCache
    @Environment(\.minidiscPlayingAccent) private var playingAccent
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var coverImage: PlatformImage?
    @State private var shareRequest: DisplayableSong?
    @State private var preparedShare: PreparedTrackShare?
    @State private var trackInformation: DisplayableSong?

    init(song: DisplayableSong, index: Int, showCoverArt: Bool = false, showArtist: Bool = true, secondaryText: String? = nil, coverArtSize: CGFloat = 44, coverArtCornerRadius: CGFloat = MinidiscCornerRadius.standard, primaryContentSpacing: CGFloat = MinidiscSpacing.s, isFavorite: Bool = false, titleColor: Color = .primary, secondaryColor: Color = .secondary, trailingAccessory: SongRowTrailingAccessory = .duration, rowAccessibilityIdentifier: String = "", onDownload: (() -> Void)? = nil, onRemoveDownload: (() -> Void)? = nil, isDownloading: Bool = false, onRemoveFromPlaylist: (() -> Void)? = nil, onAddToPlaylist: ((DisplayableSong) -> Void)? = nil, onGoToAlbum: (() -> Void)? = nil, artistCredits: [ArtistCredit] = [], onArtistsTap: (([ArtistCredit]) -> Void)? = nil, onTap: (() -> Void)? = nil) {
        self.song = song
        self.index = index
        self.showCoverArt = showCoverArt
        self.showArtist = showArtist
        self.secondaryText = secondaryText
        self.coverArtSize = coverArtSize
        self.coverArtCornerRadius = coverArtCornerRadius
        self.primaryContentSpacing = primaryContentSpacing
        self.isFavorite = isFavorite
        self.titleColor = titleColor
        self.secondaryColor = secondaryColor
        self.trailingAccessory = trailingAccessory
        self.rowAccessibilityIdentifier = rowAccessibilityIdentifier
        self.onDownload = onDownload
        self.onRemoveDownload = onRemoveDownload
        self.isDownloading = isDownloading
        self.onRemoveFromPlaylist = onRemoveFromPlaylist
        self.onAddToPlaylist = onAddToPlaylist
        self.onGoToAlbum = onGoToAlbum
        self.artistCredits = artistCredits
        self.onArtistsTap = onArtistsTap
        self.onTap = onTap
    }

    private var textLineLimit: Int {
        trailingAccessory == .favorite && dynamicTypeSize.isAccessibilitySize ? 2 : 1
    }

    /// Tappable credits need their own button, so the row uses a tap gesture instead of wrapping
    /// everything in one Button (nested buttons don't split taps reliably).
    private var showsTappableCredits: Bool { !artistCredits.isEmpty && onArtistsTap != nil }
    /// With the heart on the trailing edge, the leading favourite marker would repeat it.
    private var showsLeadingFavoriteMarker: Bool { isFavorite && trailingAccessory != .favorite }

    private var isCurrentTrack: Bool { container?.playerState.currentTrack?.id == song.id }
    private var isPlaying: Bool { container?.playerState.playbackState == .playing }
    private var actions: SongActions {
        SongActions(
            song: song,
            isFavorite: isFavorite,
            isDownloading: isDownloading,
            onDownload: onDownload,
            onRemoveDownload: onRemoveDownload,
            onRemoveFromPlaylist: onRemoveFromPlaylist,
            onAddToPlaylist: onAddToPlaylist,
            onShare: { shareRequest = song },
            onGoToAlbum: onGoToAlbum,
            onGetInfo: { trackInformation = song }
        )
    }

    var body: some View {
        HStack(spacing: MinidiscSpacing.s) {
            if let onTap, showsTappableCredits {
                // The play button fills the row behind the content. Index and title don't take touches,
                // so taps on them reach it; only the credits link on top opens artists.
                primaryContent
                    .background {
                        Button(action: onTap) {
                            Color.clear.contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(verbatim: song.title))
                        .accessibilityIdentifier(rowAccessibilityIdentifier)
                    }
            } else if let onTap {
                Button(action: onTap) {
                    primaryContent
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(rowAccessibilityIdentifier)
            } else {
                primaryContent
            }

            trailingContent
        }
        .padding(.vertical, trailingAccessory == .favorite ? MinidiscSpacing.xs : MinidiscSpacing.s)
        .contentShape(Rectangle())
        .task(id: song.id) {
            coverImage = await artworkImageCache.load(coverArtId: song.coverArtId ?? song.id)
        }
        .task(id: shareRequest?.id) {
            await prepareRequestedShare()
        }
        .sheet(item: $preparedShare) { share in
            shareSheet(for: share)
        }
        .sheet(item: $trackInformation) { track in
            TrackInformationSheet(track: track)
        }
        .contextMenu {
            actions
        } preview: {
            SongContextPreview(coverImage: coverImage, song: song)
        }
        .modifier(SongQuickActions(song: song, onAddToPlaylist: onAddToPlaylist))
    }

    private var primaryContent: some View {
        HStack(spacing: primaryContentSpacing) {
            if showCoverArt {
                CoverArtCard(
                    id: song.coverArtId ?? song.id,
                    size: coverArtSize,
                    cornerRadius: coverArtCornerRadius
                )
                    .overlay {
                        if isCurrentTrack {
                            ZStack {
                                Color.black.opacity(0.45)
                                NowPlayingBarsIndicator(isPlaying: isPlaying)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: coverArtCornerRadius))
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if showsLeadingFavoriteMarker {
                            Image(systemName: "heart.fill")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(playingAccent)
                                .padding(3)
                        }
                    }
            } else {
                ZStack {
                    if isCurrentTrack {
                        NowPlayingBarsIndicator(isPlaying: isPlaying)
                    } else {
                        Text("\(song.trackNumber ?? index)")
                            .font(.minidiscTrackNumber)
                            .foregroundStyle(secondaryColor.opacity(0.72))
                            .opacity(showsLeadingFavoriteMarker ? 0 : 1)
                        if showsLeadingFavoriteMarker {
                            Image(systemName: "heart.fill")
                                .font(.caption2)
                                .foregroundStyle(playingAccent)
                                .accessibilityLabel("Favorite")
                        }
                    }
                }
                .frame(width: 28, height: 44, alignment: .center)
                .monospacedDigit()
                .allowsHitTesting(!showsTappableCredits)
                .accessibilityHidden(showsTappableCredits)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.minidiscTrackTitle)
                    .foregroundStyle(isCurrentTrack ? playingAccent : titleColor)
                    .lineLimit(textLineLimit)
                    .fixedSize(horizontal: false, vertical: true)
                    .allowsHitTesting(!showsTappableCredits)
                    .accessibilityHidden(showsTappableCredits)
                if showsTappableCredits, let onArtistsTap {
                    TrackArtistsLine(
                        credits: artistCredits,
                        accessibilityIdentifier: rowAccessibilityIdentifier.isEmpty ? "" : rowAccessibilityIdentifier + ".credits"
                    ) { onArtistsTap(artistCredits) }
                } else if let secondaryText = secondaryText ?? (showArtist ? song.artist : nil) {
                    Text(secondaryText)
                        .font(.minidiscCellSubtitle)
                        .foregroundStyle(secondaryColor)
                        .lineLimit(textLineLimit)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
                .allowsHitTesting(!showsTappableCredits)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var trailingContent: some View {
        HStack(spacing: MinidiscSpacing.s) {
            if song.isDownloaded {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.minidiscCaption)
                    .foregroundStyle(secondaryColor.opacity(0.6))
            } else if isDownloading {
                ProgressView()
                    .scaleEffect(0.7)
                    .frame(width: 16, height: 16)
            }
            if trailingAccessory == .favorite, !song.isLocalFile {
                Button {
                    SongActions.toggleFavorite(song: song, isFavorite: isFavorite, container: container)
                } label: {
                    Image(systemName: isFavorite ? "heart.fill" : "heart")
                        .font(.body)
                        .foregroundStyle(isFavorite ? AnyShapeStyle(playingAccent) : AnyShapeStyle(secondaryColor))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: MinidiscControlSize.regular, height: MinidiscControlSize.regular)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(container?.serverState.isOnline != true)
                .accessibilityLabel(isFavorite ? "Remove from Favorites" : "Add to Favorites")
            }
            if song.duration > 0 {
                Text(Duration.seconds(song.duration).formatted(.time(pattern: .minuteSecond)))
                    .font(trailingAccessory == .favorite ? .minidiscTrackNumber : .minidiscCaption)
                    .foregroundStyle(secondaryColor.opacity(trailingAccessory == .favorite ? 0.75 : 0.6))
                    .monospacedDigit()
                    .frame(minWidth: trailingAccessory == .favorite ? MinidiscSpacing.xxxxl : nil, alignment: .trailing)
            }
        }
    }

    private func prepareRequestedShare() async {
        guard let track = shareRequest else { return }
        let share = await container?.trackSharingService.prepareShare(
            for: track,
            serverIsReachable: container?.serverState.isOnline == true
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
}

private struct SongActions: View {
    let song: DisplayableSong
    let isFavorite: Bool
    let isDownloading: Bool
    let onDownload: (() -> Void)?
    let onRemoveDownload: (() -> Void)?
    let onRemoveFromPlaylist: (() -> Void)?
    let onAddToPlaylist: ((DisplayableSong) -> Void)?
    let onShare: () -> Void
    let onGoToAlbum: (() -> Void)?
    let onGetInfo: (() -> Void)?

    @Environment(\.appContainer) private var container
    @Environment(PlaylistAddition.self) private var playlistAddition: PlaylistAddition?

    private var isOnline: Bool { container?.serverState.isOnline == true }

    var body: some View {
        Group {
            if !song.isLocalFile {
                ControlGroup {
                    if song.isDownloaded {
                        Button("Downloaded", systemImage: "arrow.down.circle.fill") { }
                            .disabled(true)
                    } else if isDownloading {
                        Button("Downloading…", systemImage: "arrow.down.circle.fill") { }
                            .disabled(true)
                    } else {
                        Button("Download", systemImage: "arrow.down.circle.fill") {
                            onDownload?()
                        }
                        .disabled(onDownload == nil)
                    }

                    Button("Share", systemImage: "square.and.arrow.up.fill", action: onShare)

                    if isFavorite {
                        Button("Undo", systemImage: "heart.slash.fill") {
                            Self.toggleFavorite(song: song, isFavorite: isFavorite, container: container)
                        }
                        .disabled(!isOnline)
                    } else {
                        Button("Favorite", systemImage: "heart.fill") {
                            Self.toggleFavorite(song: song, isFavorite: isFavorite, container: container)
                        }
                        .disabled(!isOnline)
                    }
                }

                Section {
                    Button {
                        if let onAddToPlaylist { onAddToPlaylist(song) }
                        else { playlistAddition?.present(song) }
                    } label: {
                        Label("Add to Playlist...", systemImage: "music.note.list")
                    }
                    .disabled(!isOnline || (onAddToPlaylist == nil && playlistAddition == nil))
                }
            }

            Section {
                Button {
                    Task { await container?.playerService.playNext(song) }
                } label: {
                    Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                }

                Button {
                    Task { await container?.playerService.addToQueue(song) }
                } label: {
                    Label("Add to Queue", systemImage: "text.append")
                }
            }

            if onGoToAlbum != nil || onGetInfo != nil {
                Section {
                    if let onGoToAlbum,
                       song.albumId != nil,
                       song.albumName?.isEmpty == false {
                        Button(action: onGoToAlbum) {
                            Label("Go to Album", systemImage: "music.note.square.stack")
                        }
                        .disabled(!isOnline)
                    }

                    if let onGetInfo {
                        Button("Get Info", systemImage: "info.circle.fill", action: onGetInfo)
                    }
                }
            }

            if !song.isLocalFile {
                Section {
                    Button {
                        startInstantMix(from: .song(id: song.id), using: container, startingWith: song)
                    } label: {
                        Label("Instant Mix", systemImage: instantMixSymbol)
                    }
                }
            }

            if onRemoveFromPlaylist != nil || (song.isDownloaded && onRemoveDownload != nil) {
                Section {
                    if let onRemoveFromPlaylist {
                        Button(role: .destructive, action: onRemoveFromPlaylist) {
                            Label("Remove from Playlist", systemImage: "minus.circle")
                        }
                    }

                    if song.isDownloaded, let onRemoveDownload {
                        Button(role: .destructive, action: onRemoveDownload) {
                            Label("Remove Download", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .tint(.primary)
    }

    static func toggleFavorite(song: DisplayableSong, isFavorite: Bool, container: AppContainer?) {
        HapticFeedback.light.trigger()
        Task {
            if isFavorite {
                await container?.toastService.perform {
                    try await container?.favoritesService.unstar(itemType: .song, itemId: song.id)
                }
            } else {
                await container?.toastService.perform {
                    try await container?.favoritesService.star(itemType: .song, itemId: song.id)
                }
            }
        }
    }
}
