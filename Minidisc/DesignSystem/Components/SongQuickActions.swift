import SwiftUI

/// The same two queue actions are available on every song row. Lists support them on iOS 26;
/// scroll-based detail pages opt into the native swipe coordinator on iOS 27.
struct SongQuickActions: ViewModifier {
    let song: DisplayableSong
    var onAddToPlaylist: ((DisplayableSong) -> Void)?
    var onRemove: (() -> Void)? = nil
    @Environment(\.appContainer) private var container
    @Environment(PlaylistAddition.self) private var playlistAddition: PlaylistAddition?

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if container?.playerState.isLiveStream != true {
                    Button {
                        HapticFeedback.light.trigger()
                        Task { await container?.playerService.playNext(song) }
                    } label: {
                        Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                    }
                    .tint(.orange)
                    Button {
                        HapticFeedback.light.trigger()
                        Task { await container?.playerService.addToQueue(song) }
                    } label: {
                        Label("Add to Queue", systemImage: "text.append")
                    }
                    .tint(.purple)
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if let onRemove {
                    Button(role: .destructive, action: onRemove) {
                        Label("Remove from Queue", systemImage: "minus.circle")
                    }
                } else {
                    Button {
                        if let onAddToPlaylist { onAddToPlaylist(song) }
                        else { playlistAddition?.present(song) }
                    } label: {
                        Label("Add to Playlist...", systemImage: "music.note.list")
                    }
                    .tint(Color.minidiscAccent)
                    .disabled(container?.serverState.isOnline != true || (onAddToPlaylist == nil && playlistAddition == nil))
                }
            }
    }
}

private struct SongSwipeContainer: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 27, macOS 27, *) {
            content.swipeActionsContainer()
        } else {
            content
        }
    }
}

extension View {
    func minidiscSongSwipeContainer() -> some View { modifier(SongSwipeContainer()) }
}
