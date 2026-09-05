import SwiftUI

nonisolated enum SongRowTrailingAccessory: Sendable, Equatable {
    case duration
    case menu
}

/// Standard track cell for album and playlist detail screens.
///
/// - `showCoverArt`: show a 44pt thumbnail (useful in playlist context where tracks
///   may come from different albums). Default `false` for album tracks.
struct SongRow: View {
    let song: DisplayableSong
    let index: Int
    var showCoverArt: Bool = false
    /// Show the artist as the subtitle. Default true; pass false where the artist is implied (e.g. the artist
    /// detail page) so the row isn't redundant.
    var showArtist: Bool = true
    /// Optional context-specific secondary line, such as the album title on an artist's top songs.
    var secondaryText: String? = nil
    var coverArtSize: CGFloat = 44
    var coverArtCornerRadius: CGFloat = MinidiscCornerRadius.standard
    var primaryContentSpacing: CGFloat = MinidiscSpacing.s
    var isFavorite: Bool = false
    var titleColor: Color = .primary
    var secondaryColor: Color = .secondary
    var trailingAccessory: SongRowTrailingAccessory = .duration
    var menuAccessibilityIdentifier: String = ""
    let onDownload: (() -> Void)?
    let onRemoveDownload: (() -> Void)?
    var isDownloading: Bool = false
    var onRemoveFromPlaylist: (() -> Void)? = nil
    var onAddToPlaylist: ((DisplayableSong) -> Void)? = nil
    var onGoToAlbum: (() -> Void)? = nil
    var onTap: (() -> Void)? = nil

    @Environment(\.appContainer) private var container
    @Environment(ArtworkImageCache.self) private var artworkImageCache
    @Environment(\.minidiscPlayingAccent) private var playingAccent
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var menuSymbolSize: CGFloat = 17
    @State private var coverImage: PlatformImage?
    @State private var shareRequest: DisplayableSong?
    @State private var preparedShare: PreparedTrackShare?
    @State private var trackInformation: DisplayableSong?

    init(song: DisplayableSong, index: Int, showCoverArt: Bool = false, showArtist: Bool = true, secondaryText: String? = nil, coverArtSize: CGFloat = 44, coverArtCornerRadius: CGFloat = MinidiscCornerRadius.standard, primaryContentSpacing: CGFloat = MinidiscSpacing.s, isFavorite: Bool = false, titleColor: Color = .primary, secondaryColor: Color = .secondary, trailingAccessory: SongRowTrailingAccessory = .duration, menuAccessibilityIdentifier: String = "", onDownload: (() -> Void)? = nil, onRemoveDownload: (() -> Void)? = nil, isDownloading: Bool = false, onRemoveFromPlaylist: (() -> Void)? = nil, onAddToPlaylist: ((DisplayableSong) -> Void)? = nil, onGoToAlbum: (() -> Void)? = nil, onTap: (() -> Void)? = nil) {
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
        self.menuAccessibilityIdentifier = menuAccessibilityIdentifier
        self.onDownload = onDownload
        self.onRemoveDownload = onRemoveDownload
        self.isDownloading = isDownloading
        self.onRemoveFromPlaylist = onRemoveFromPlaylist
        self.onAddToPlaylist = onAddToPlaylist
        self.onGoToAlbum = onGoToAlbum
        self.onTap = onTap
    }

    private var textLineLimit: Int {
        trailingAccessory == .menu && dynamicTypeSize.isAccessibilitySize ? 2 : 1
    }

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
            onGetInfo: trailingAccessory == .menu ? { trackInformation = song } : nil
        )
    }

    var body: some View {
        HStack(spacing: MinidiscSpacing.s) {
            if let onTap {
                Button(action: onTap) {
                    primaryContent
                }
                .buttonStyle(.plain)
            } else {
                primaryContent
            }

            trailingContent
        }
        .padding(.vertical, trailingAccessory == .menu ? 0 : MinidiscSpacing.s)
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
                        // Now-playing equalizer over the thumbnail (with a scrim) for the current track —
                        // restores the playing cue lost when rows switched to album thumbnails (showCoverArt).
                        if isCurrentTrack {
                            ZStack {
                                Color.black.opacity(0.45)
                                NowPlayingBarsIndicator(isPlaying: isPlaying)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: coverArtCornerRadius))
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if isFavorite {
                            Image(systemName: "star.fill")
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
                            .font(.minidiscCellSubtitle)
                            .foregroundStyle(secondaryColor.opacity(0.72))
                            .opacity(isFavorite ? 0 : 1)
                        if isFavorite {
                            Image(systemName: "star.fill")
                                .font(.caption2)
                                .foregroundStyle(playingAccent)
                                .accessibilityLabel("Favorite")
                        }
                    }
                }
                .frame(width: 28, height: 44, alignment: .center)
                .monospacedDigit()
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.minidiscBody)
                    .foregroundStyle(isCurrentTrack ? playingAccent : titleColor)
                    .lineLimit(textLineLimit)
                    .fixedSize(horizontal: false, vertical: true)
                if let secondaryText = secondaryText ?? (showArtist ? song.artist : nil) {
                    Text(secondaryText)
                        .font(.minidiscCellSubtitle)
                        .foregroundStyle(secondaryColor)
                        .lineLimit(textLineLimit)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
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
            switch trailingAccessory {
            case .duration:
                if song.duration > 0 {
                    Text(Duration.seconds(song.duration).formatted(.time(pattern: .minuteSecond)))
                        .font(.minidiscCaption)
                        .foregroundStyle(secondaryColor.opacity(0.6))
                        .monospacedDigit()
                }
            case .menu:
                Menu {
                    actions
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: min(menuSymbolSize, 22), weight: .semibold))
                        .foregroundStyle(secondaryColor)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .tint(secondaryColor)
                .menuOrder(.fixed)
                .accessibilityLabel("More options")
                .accessibilityIdentifier(menuAccessibilityIdentifier)
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
                    Button("Undo", systemImage: "star.slash.fill") {
                        toggleFavorite()
                    }
                    .disabled(!isOnline)
                } else {
                    Button("Favorite", systemImage: "star.fill") {
                        toggleFavorite()
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
                       let albumName = song.albumName,
                       !albumName.isEmpty {
                        Button(action: onGoToAlbum) {
                            Label("Go to Album", systemImage: "music.note.square.stack")
                            Text(albumName)
                        }
                        .disabled(!isOnline)
                    }

                    if let onGetInfo {
                        Button("Get Info", systemImage: "info.circle.fill", action: onGetInfo)
                    }
                }
            }

            Section {
                Button {
                    startInstantMix(from: .song(id: song.id), using: container, startingWith: song)
                } label: {
                    Label("Instant Mix", systemImage: instantMixSymbol)
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

    private func toggleFavorite() {
        HapticFeedback.light.trigger()
        Task {
            if isFavorite {
                try? await container?.favoritesService.unstar(itemType: .song, itemId: song.id)
            } else {
                try? await container?.favoritesService.star(itemType: .song, itemId: song.id)
            }
        }
    }
}
