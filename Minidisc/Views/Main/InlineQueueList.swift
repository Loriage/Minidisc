import SwiftUI
import SwiftData
import OSLog
import UniformTypeIdentifiers

private struct QueueRow: View {
    let song: DisplayableSong
    let isCurrent: Bool
    let onRemove: (() -> Void)?
    // InlineQueueList passes the full player's luminance-adaptive content colors so text reads over the
    // cover blur; the label defaults cover any caller that doesn't.
    var contentColor: Color = .primary
    var secondaryContentColor: Color = .secondary
    var loadArtwork: Bool = true

    @Environment(\.appContainer) private var container
    @Environment(PlaylistAddition.self) private var playlistAddition
    @Environment(\.minidiscPlayingAccent) private var playingAccent
    @Query private var favoriteMatches: [FavoriteRecord]

    init(song: DisplayableSong, isCurrent: Bool, onRemove: (() -> Void)? = nil,
         contentColor: Color = .primary, secondaryContentColor: Color = .secondary, loadArtwork: Bool = true) {
        self.song = song
        self.isCurrent = isCurrent
        self.onRemove = onRemove
        self.contentColor = contentColor
        self.secondaryContentColor = secondaryContentColor
        self.loadArtwork = loadArtwork
        let cid = "song:\(song.id)"
        _favoriteMatches = Query(filter: #Predicate<FavoriteRecord> { $0.id == cid })
    }

    private var isOnline: Bool { container?.serverState.isOnline == true }
    private var isPlaying: Bool { container?.playerState.playbackState == .playing }
    private var isFavorite: Bool { !favoriteMatches.isEmpty }

    var body: some View {
        HStack(spacing: MinidiscSpacing.m) {
            CoverArtView(id: song.coverArtId ?? song.id, size: 88, loadingEnabled: loadArtwork)
                .frame(width: 44, height: 44)
                .minidiscCoverStyle(cornerRadius: MinidiscCornerRadius.xs)

            VStack(alignment: .leading, spacing: MinidiscSpacing.xs) {
                Text(song.title)
                    .font(.minidiscCellTitle)
                    .foregroundStyle(isCurrent ? playingAccent : contentColor)
                    .lineLimit(1)
                if let artist = song.artist {
                    Text(artist)
                        .font(.minidiscCaption)
                        .foregroundStyle(secondaryContentColor)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if isCurrent {
                NowPlayingBarsIndicator(isPlaying: isPlaying)
            } else {
            }
        }
        .padding(.vertical, MinidiscSpacing.xs)
        .contextMenu {
            Group {
            Button {
                Task {
                    do {
                        try await container?.playerService.play(tracks: [song], startIndex: 0)
                    } catch {
                        Logger.player.error("[PLAYBACK] play failed: \(error, privacy: .public)")
                    }
                }
            } label: {
                Label("Play", systemImage: "play.fill")
            }

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

            Divider()

            Button {
                playlistAddition.present(song)
            } label: {
                Label("Add to Playlist...", systemImage: "music.note.list")
            }
            .disabled(!isOnline)

            Divider()

            Button {
                let fav = isFavorite
                Task {
                    if fav {
                        try? await container?.favoritesService.unstar(itemType: .song, itemId: song.id)
                    } else {
                        try? await container?.favoritesService.star(itemType: .song, itemId: song.id)
                    }
                }
            } label: {
                Label(
                    isFavorite ? "Remove from Favorites" : "Add to Favorites",
                    systemImage: isFavorite ? "star.slash" : "star"
                )
            }
            .disabled(!isOnline)

            if let onRemove {
                Divider()
                Button(role: .destructive, action: onRemove) {
                    Label("Remove from Queue", systemImage: "minus.circle")
                }
            }
            }
            .tint(.primary)
        }
    }
}

/// The iOS Up Next reorder list on FullPlayerView's inline queue surface.
/// Native `List` + `.onMove` (always-on edit mode) — offset-based, so
/// duplicate-safe — rendered transparently over the player's blurred background. Removal is via the row
/// context menu (no edit-mode delete circles); tap-to-play stays in the queue surface.
struct InlineQueueList: View {
    let playerState: PlayerState
    var contentColor: Color = .primary
    var secondaryContentColor: Color = .secondary
    /// Defer row artwork loads until the queue is actually visible (it is mounted at opacity 0 for the
    /// morph). The List stays mounted with stable identity — only the per-row artwork task is gated.
    var loadArtwork: Bool = true
    @Environment(\.appContainer) private var container

    var body: some View {
        let queue = playerState.queue
        let currentIndex = playerState.currentIndex
        let upNext = Array(queue.dropFirst(currentIndex + 1))

        if upNext.isEmpty {
            EmptyStateView(
                systemImage: "list.bullet",
                title: "Nothing up next",
                subtitle: "Tracks you add to the queue appear here."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(Array(upNext.enumerated()), id: \.offset) { offset, song in
                    let absoluteIndex = currentIndex + 1 + offset
                    QueueRow(song: song, isCurrent: false, onRemove: { removeFromQueue(at: absoluteIndex) },
                             contentColor: contentColor, secondaryContentColor: secondaryContentColor,
                             loadArtwork: loadArtwork)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            HapticFeedback.medium.trigger()
                            Task {
                                do {
                                    guard let playerState = container?.playerState,
                                          let selection = QueueTrackSelection(
                                              playerState: playerState,
                                              destinationIndex: absoluteIndex,
                                              destinationTrackID: song.id
                                          ) else {
                                        return
                                    }
                                    _ = try await container?.playerService.selectQueueTrack(selection)
                                } catch {
                                    Logger.player.error("[PLAYBACK] play failed: \(error, privacy: .public)")
                                }
                            }
                        }
                }
                .onMove { source, destination in
                    // Native offset-based reorder — duplicate-safe; destination is the moveInQueue toOffset.
                    guard let relativeSource = source.first else { return }
                    let absoluteSource = currentIndex + 1 + relativeSource
                    let absoluteDestination = currentIndex + 1 + destination
                    HapticFeedback.light.trigger()
                    Task { await container?.playerService.moveInQueue(fromIndex: absoluteSource, toIndex: absoluteDestination) }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.editMode, .constant(.active))
        }
    }

    private func removeFromQueue(at index: Int) {
        Task {
            guard let queue = container?.playerState.queue, index >= 0, index < queue.count else { return }
            HapticFeedback.light.trigger()
            await container?.playerService.removeFromQueue(at: index)
        }
    }
}
