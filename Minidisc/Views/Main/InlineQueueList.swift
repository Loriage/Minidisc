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
    var showsReorderHint: Bool = false

    @Environment(\.appContainer) private var container
    @Environment(PlaylistAddition.self) private var playlistAddition
    @Environment(\.minidiscPlayingAccent) private var playingAccent
    @Query private var favoriteMatches: [FavoriteRecord]

    init(song: DisplayableSong, isCurrent: Bool, onRemove: (() -> Void)? = nil,
         contentColor: Color = .primary, secondaryContentColor: Color = .secondary, loadArtwork: Bool = true,
         showsReorderHint: Bool = false) {
        self.song = song
        self.isCurrent = isCurrent
        self.onRemove = onRemove
        self.contentColor = contentColor
        self.secondaryContentColor = secondaryContentColor
        self.loadArtwork = loadArtwork
        self.showsReorderHint = showsReorderHint
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
            } else if showsReorderHint {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(secondaryContentColor.opacity(0.5))
                    .accessibilityHidden(true)
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
                if !UserFacingError.isCancellation(error) {
                    container?.toastService.showError(UserFacingError.from(error).displayMessage)
                }
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
                        await container?.toastService.perform { try await container?.favoritesService.unstar(itemType: .song, itemId: song.id) }
                    } else {
                        await container?.toastService.perform { try await container?.favoritesService.star(itemType: .song, itemId: song.id) }
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
        .modifier(SongQuickActions(song: song, onAddToPlaylist: playlistAddition.present, onRemove: onRemove))
    }
}

/// The next songs remain directly below the playback modes. Native drag and swipe can coexist
/// on iOS 27; the earlier system keeps the existing always-visible reorder handles.
struct InlineQueueList: View {
    let playerState: PlayerState
    var contentColor: Color = .primary
    var secondaryContentColor: Color = .secondary
    var loadArtwork: Bool = true

    var body: some View {
        let entries = QueueRowSnapshot.capture(playerState)
        if entries.isEmpty {
            EmptyStateView(systemImage: "list.bullet", title: "Nothing up next",
                           subtitle: "Tracks you add to the queue appear here.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if #available(iOS 27, *) {
            ReorderableQueueList(entries: entries, queueCount: playerState.queue.count,
                                 contentColor: contentColor, secondaryContentColor: secondaryContentColor,
                                 loadArtwork: loadArtwork)
        } else {
            LegacyQueueList(entries: entries, queueCount: playerState.queue.count,
                            contentColor: contentColor, secondaryContentColor: secondaryContentColor,
                            loadArtwork: loadArtwork)
        }
    }
}

private struct QueueRowSnapshot: Identifiable {
    struct ID: Hashable {
        let generation: UInt64
        let songID: String
        let occurrence: Int
    }
    let id: ID
    let song: DisplayableSong
    let selection: QueueTrackSelection

    @MainActor
    static func capture(_ state: PlayerState) -> [Self] {
        var occurrences: [String: Int] = [:]
        return state.queue.enumerated().compactMap { index, song in
            let occurrence = occurrences[song.id, default: 0]
            occurrences[song.id] = occurrence + 1
            guard index > state.currentIndex,
                  let selection = QueueTrackSelection(playerState: state, destinationIndex: index,
                                                      destinationTrackID: song.id) else { return nil }
            return Self(id: ID(generation: state.queueGeneration, songID: song.id, occurrence: occurrence),
                        song: song, selection: selection)
        }
    }
}

private struct QueueEntryRow: View {
    let entry: QueueRowSnapshot
    let contentColor: Color
    let secondaryContentColor: Color
    let loadArtwork: Bool
    var showsReorderHint = false
    @Environment(\.appContainer) private var container

    var body: some View {
        QueueRow(song: entry.song, isCurrent: false, onRemove: remove,
                 contentColor: contentColor, secondaryContentColor: secondaryContentColor,
                 loadArtwork: loadArtwork, showsReorderHint: showsReorderHint)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .contentShape(Rectangle())
            .accessibilityIdentifier("queue.track.\(entry.song.id).\(entry.id.occurrence)")
            .onTapGesture {
                HapticFeedback.medium.trigger()
                Task {
                    await container?.toastService.perform {
                        _ = try await container?.playerService.selectQueueTrack(entry.selection)
                    }
                }
            }
    }

    private func remove() {
        Task {
            guard let removal = await container?.playerService.removeQueueTrack(entry.selection) else { return }
            HapticFeedback.light.trigger()
            container?.toastService.show(String(localized: "Removed from queue"), subtitle: removal.song.title,
                                         style: .success, duration: 6, coverArtId: removal.song.coverArtId,
                                         action: .undoQueueRemoval(removal))
        }
    }
}

@available(iOS 27, *)
private struct ReorderableQueueList: View {
    let entries: [QueueRowSnapshot]
    let queueCount: Int
    let contentColor: Color
    let secondaryContentColor: Color
    let loadArtwork: Bool
    @Environment(\.appContainer) private var container

    var body: some View {
        List {
            ForEach(entries) { entry in
                QueueEntryRow(entry: entry, contentColor: contentColor, secondaryContentColor: secondaryContentColor,
                              loadArtwork: loadArtwork, showsReorderHint: true)
            }
            .reorderable()
        }
        .reorderContainer(for: QueueRowSnapshot.self) { difference in
            guard difference.sources.count == 1,
                  let source = difference.sources.first,
                  let entry = entries.first(where: { $0.id == source }) else { return }
            let destination: Int
            switch difference.destination.position {
            case .before(let id):
                guard let target = entries.first(where: { $0.id == id }) else { return }
                destination = target.selection.destinationIndex
            case .end:
                destination = queueCount
            }
            HapticFeedback.light.trigger()
            Task { await container?.playerService.moveQueueTrack(entry.selection, toIndex: destination) }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

private struct LegacyQueueList: View {
    let entries: [QueueRowSnapshot]
    let queueCount: Int
    let contentColor: Color
    let secondaryContentColor: Color
    let loadArtwork: Bool
    @Environment(\.appContainer) private var container

    var body: some View {
        List {
            ForEach(entries) { entry in
                QueueEntryRow(entry: entry, contentColor: contentColor, secondaryContentColor: secondaryContentColor,
                              loadArtwork: loadArtwork)
            }
            .onMove { sources, destination in
                guard let source = sources.first, entries.indices.contains(source) else { return }
                let entry = entries[source]
                let target = entries.indices.contains(destination) ? entries[destination].selection.destinationIndex : queueCount
                HapticFeedback.light.trigger()
                Task { await container?.playerService.moveQueueTrack(entry.selection, toIndex: target) }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.editMode, .constant(.active))
    }
}
