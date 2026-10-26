import SwiftUI
import SwiftSonic

/// Keep source routing below the shared rows and cards, so adding a server does not
/// change the library's layout or send local collection identifiers to its API.
struct MusicAlbumLink<Label: View>: View {
    let album: AlbumID3
    @ViewBuilder let label: () -> Label
    @Environment(\.appContainer) private var container

    var body: some View {
        if let group = container?.localMusic.catalog.groups[album.id] {
            NavigationLink { LocalMusicCollectionView(group: group, category: .albums) } label: { label() }
        } else {
            NavigationLink(value: HomeDestination.album(album), label: label)
        }
    }
}

struct MusicArtistLink<Label: View>: View {
    let artist: ArtistID3
    @ViewBuilder let label: () -> Label
    @Environment(\.appContainer) private var container

    var body: some View {
        if let group = container?.localMusic.catalog.groups[artist.id] {
            NavigationLink { LocalMusicCollectionView(group: group, category: .artists) } label: { label() }
        } else {
            NavigationLink(value: HomeDestination.artist(artist), label: label)
        }
    }
}

struct LocalCollectionContextMenu: ViewModifier {
    let id: String
    @Environment(\.appContainer) private var container

    func body(content: Content) -> some View {
        content.contextMenu {
            if let tracks = container?.localMusic.catalog.groups[id]?.tracks {
                Button("Play", systemImage: "play.fill") { play(tracks, order: .ordered) }
                Button("Shuffle", systemImage: "shuffle") { play(tracks, order: .shuffled) }
                Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                    Task { await container?.playerService.playNext(tracks.filter(\.isAvailable).map(\.song)) }
                }
                Button("Add to Queue", systemImage: "text.append") {
                    Task { await container?.playerService.addToQueue(tracks.filter(\.isAvailable).map(\.song)) }
                }
            }
        }
    }

    private func play(_ tracks: [LocalMusicTrack], order: PreparedPlaybackQueue.Order) {
        Task {
            await container?.toastService.perform {
                try await container?.playerService.play(preparingQueue: {
                    try LocalMusicTrack.playbackQueue(tracks, order: order)
                })
            }
        }
    }
}

struct MusicLibraryEmptyView: View {
    @State private var choosingFolder = false

    var body: some View {
        ContentUnavailableView {
            Label("No music yet", systemImage: "music.note.list")
        } description: {
            Text("Add music folders from Files. Your audio stays where it is.", tableName: "LocalMusic")
        } actions: {
            Button { choosingFolder = true } label: {
                Label { Text("Add Folder", tableName: "LocalMusic") } icon: { Image(systemName: "folder.badge.plus") }
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("localMusic.addFolder")
        }
        .modifier(LocalMusicFolderPicker(isPresented: $choosingFolder))
    }
}

struct LocalMusicHomeSections: View {
    @Environment(\.appContainer) private var container

    var body: some View {
        if let catalog = container?.localMusic.catalog, !catalog.songs.isEmpty {
            HomeAlbumSection(title: "Recently Added", albums: AlbumSort.recentlyAdded.sorted(catalog.albums), identifier: "home.localAlbums")
            MinidiscShelf {
                MinidiscCarouselHeaderLink("Artists", itemCount: catalog.artists.count) { ArtistListView() }
            } content: {
                ForEach(Array(catalog.artists.prefix(MinidiscCarouselMetrics.previewLimit))) { artist in
                    MusicArtistLink(artist: artist) { ArtistGridCard(artist: artist).frame(width: 160) }
                        .buttonStyle(.plain)
                }
            }
        }
    }
}
