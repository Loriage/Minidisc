import SwiftUI
import SwiftData
import SwiftSonic

struct SearchScopeBar: View {
    @Binding var selection: LibrarySearchScope

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: MinidiscSpacing.s) {
                ForEach(LibrarySearchScope.allCases) { scope in
                    Button {
                        selection = scope
                        HapticFeedback.light.trigger()
                    } label: {
                        Text(scope.title)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, MinidiscSpacing.l)
                            .frame(minHeight: 44)
                            .foregroundStyle(selection == scope ? Color.white : .primary)
                            .background(selection == scope ? Color.minidiscAccent : Color.primary.opacity(0.06), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selection == scope ? [.isSelected] : [])
                    .accessibilityIdentifier("search.scope.\(scope.rawValue)")
                }
            }
            .padding(.horizontal, MinidiscSpacing.l)
        }
        .clipped()
        .padding(.vertical, MinidiscSpacing.s)
    }
}

struct SearchResultsContent: View {
    let matches: [LibrarySearchMatch]
    @Binding var scope: LibrarySearchScope
    let onAddToPlaylist: (DisplayableSong) -> Void
    let canSelectSongs: Bool
    let onSelectSongs: () -> Void
    @Query private var favorites: [FavoriteRecord]

    private var songs: [DisplayableSong] {
        matches.compactMap { if case .song(let song) = $0 { song } else { nil } }
    }

    private var groups: [LibrarySearchScope] {
        var seen = Set<LibrarySearchScope>()
        return matches.map(\.scope).filter { seen.insert($0).inserted }
    }

    var body: some View {
        let favoriteIds = Set(favorites.map(\.id))
        let best = scope == .all ? matches.first : nil
        if let best {
            Section {
                SearchMatchRow(match: best, songs: songs, isFavorite: favoriteIds.contains(best.id),
                               onAddToPlaylist: onAddToPlaylist)
                    .accessibilityIdentifier("search.topResult.\(best.id)")
            } header: {
                SearchResultsHeader(title: "Top Result", canSelectSongs: canSelectSongs,
                                    onSelectSongs: best.scope == .songs ? onSelectSongs : nil)
            }
        }
        ForEach(scope == .all ? groups : [scope]) { group in
            let values = matches.filter { $0.scope == group && $0.id != best?.id }
            if !values.isEmpty {
                Section {
                    ForEach(scope == .all ? Array(values.prefix(5)) : values) { match in
                        SearchMatchRow(match: match, songs: songs, isFavorite: favoriteIds.contains(match.id),
                                       onAddToPlaylist: onAddToPlaylist)
                            .accessibilityIdentifier("search.result.\(match.id)")
                    }
                    if scope == .all, values.count > 5 {
                        Button("See All") { scope = group }
                            .frame(minHeight: 44)
                    }
                } header: {
                    SearchResultsHeader(title: group.title, canSelectSongs: canSelectSongs,
                                        onSelectSongs: group == .songs && best?.scope != .songs ? onSelectSongs : nil)
                }
            }
        }
    }
}

private struct SearchResultsHeader: View {
    let title: LocalizedStringResource
    let canSelectSongs: Bool
    let onSelectSongs: (() -> Void)?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var layout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: MinidiscSpacing.s))
            : AnyLayout(HStackLayout(spacing: MinidiscSpacing.s))
    }

    var body: some View {
        layout {
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
            if let onSelectSongs {
                Button("Select", action: onSelectSongs)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.minidiscAccent)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 44, minHeight: 44)
                    .buttonStyle(.plain)
                    .disabled(!canSelectSongs)
                    .accessibilityLabel("Select Songs")
                    .accessibilityIdentifier("search.selectSongs")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textCase(nil)
    }
}

private struct SearchMatchRow: View {
    let match: LibrarySearchMatch
    let songs: [DisplayableSong]
    let isFavorite: Bool
    let onAddToPlaylist: (DisplayableSong) -> Void
    @Environment(\.appContainer) private var container

    var body: some View {
        switch match {
        case .song(let song):
            SongRow(song: song, index: 1, showCoverArt: true, isFavorite: isFavorite,
                    trailingAccessory: .menu, onAddToPlaylist: onAddToPlaylist, onTap: {
                Task {
                    await container?.toastService.perform {
                        try await container?.playerService.play(tracks: songs, startIndex: songs.firstIndex { $0.id == song.id } ?? 0)
                    }
                }
            })
        case .album(let album):
            NavigationLink(value: album) {
                AlbumRow(albumId: album.id, name: album.name, artist: album.artist,
                         year: album.year, coverArtId: album.coverArt)
            }
        case .artist(let artist):
            NavigationLink(value: artist) { ArtistRow(artist: artist) }
        case .playlist(let playlist):
            NavigationLink(value: HomeDestination.playlist(playlist)) {
                SearchPlaylistRow(playlist: playlist)
            }
        }
    }
}

struct SearchPlaylistRow: View {
    let playlist: Playlist
    var body: some View {
        HStack(spacing: MinidiscSpacing.m) {
            PlaylistCoverThumbnail(playlistId: playlist.id, serverId: nil,
                                   coverArtId: playlist.coverArt ?? playlist.id,
                                   title: playlist.name, size: 56)
            VStack(alignment: .leading, spacing: MinidiscSpacing.xs) {
                Text(playlist.name).font(.minidiscCellTitle).lineLimit(2)
                Text("\(playlist.songCount) tracks")
                    .font(.minidiscCellSubtitle).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, MinidiscSpacing.xs)
        .collectionContextMenu(itemType: .playlist, itemId: playlist.id, displayName: playlist.name,
                               displaySubtitle: playlist.owner ?? "", coverArtId: playlist.coverArt)
    }
}

struct SearchRetryRow: View {
    let message: String
    let retry: () -> Void
    var body: some View {
        HStack(spacing: MinidiscSpacing.m) {
            Text(message).font(.subheadline).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("Retry", action: retry).frame(minHeight: 44)
        }
        .listRowSeparator(.hidden)
    }
}
