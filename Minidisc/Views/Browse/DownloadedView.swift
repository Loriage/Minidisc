import SwiftUI
import SwiftData

struct DownloadedView: View {
    @Environment(\.appContainer) private var container

    var body: some View {
        Group {
            if let serverId = container?.serverState.activeServer?.id {
                DownloadedContent(serverId: serverId)
            } else {
                EmptyStateView(
                    systemImage: "arrow.down.circle",
                    title: "No Server",
                    subtitle: "Connect to a server to manage downloads."
                )
            }
        }
        .minidiscContentWidth()
        .navigationTitle("Downloads")
        .toolbarTitleDisplayMode(.inline)
    }
}

// MARK: - Content

private struct DownloadedContent: View {
    @Environment(\.appContainer) private var container
    let serverId: UUID
    @Query private var albums: [DownloadedAlbum]
    @Query private var playlists: [DownloadedPlaylist]
    @Query private var tracks: [DownloadedTrack]

    init(serverId: UUID) {
        self.serverId = serverId
        let sid = serverId
        _albums = Query(
            filter: #Predicate<DownloadedAlbum> { album in album.serverId == sid },
            sort: [SortDescriptor(\DownloadedAlbum.name)]
        )
        _playlists = Query(
            filter: #Predicate<DownloadedPlaylist> { playlist in playlist.serverId == sid },
            sort: [SortDescriptor(\DownloadedPlaylist.name)]
        )
        _tracks = Query(filter: #Predicate<DownloadedTrack> { track in track.serverId == sid })
    }

    private var displayAlbums: [DownloadedAlbumDisplay] {
        DownloadedAlbumMerger.merge(records: albums, tracks: tracks)
    }

    private var standaloneSongs: [DisplayableSong] {
        tracks.filter { $0.albumId == nil }.map { DisplayableSong(from: $0) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        if displayAlbums.isEmpty && playlists.isEmpty && standaloneSongs.isEmpty &&
            container?.downloadActivity.transfers.contains(where: { $0.serverId == serverId }) != true {
            EmptyStateView(
                systemImage: "arrow.down.circle",
                title: "Nothing downloaded",
                subtitle: "Albums and playlists you download will be available here, even offline."
            )
        } else {
            downloadedListiOS
        }
    }

    private var downloadedListiOS: some View {
        let songs = standaloneSongs
        let albums = displayAlbums
        let orderedPlaylists = playlists.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let index = songs.map { AlphabetScrollEntry(id: $0.downloadScrollID, name: $0.title) }
            + albums.map { AlphabetScrollEntry(id: $0.downloadScrollID, name: $0.name) }
            + orderedPlaylists.map { AlphabetScrollEntry(id: $0.downloadScrollID, name: $0.name) }
        return AlphabetIndexedContent(entries: index) {
            List {
                DownloadActivitySection(serverID: serverId)
                if !songs.isEmpty {
                    Section("Songs") {
                        ForEach(songs, id: \.downloadScrollID) { song in
                            Button {
                                guard let index = songs.firstIndex(where: { $0.id == song.id }) else { return }
                                Task { await container?.toastService.perform {
                                    try await container?.playerService.play(tracks: songs, startIndex: index)
                                } }
                            } label: {
                                VStack(alignment: .leading, spacing: MinidiscSpacing.xs) {
                                    Text(song.title).foregroundStyle(.primary)
                                    if let artist = song.artist {
                                        Text(artist).font(.subheadline).foregroundStyle(.secondary)
                                    }
                                }
                                .frame(minHeight: 44, alignment: .leading)
                            }
                            .id(song.downloadScrollID)
                            .accessibilityIdentifier("downloads.song.\(song.id)")
                            .contextMenu {
                                Button("Remove Download", systemImage: "trash", role: .destructive) {
                                    Task { await container?.toastService.perform {
                                        try await container?.downloadService.remove(songId: song.id, serverId: serverId)
                                    } }
                                }
                            }
                        }
                    }
                }
                if !albums.isEmpty {
                    Section("Albums") {
                        ForEach(albums, id: \.downloadScrollID) { display in
                            NavigationLink(value: HomeDestination.downloadedAlbum(display)) {
                                HStack(spacing: MinidiscSpacing.m) {
                                    CoverArtCard(id: display.coverArtId ?? display.albumId, size: 56)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(display.name)
                                            .font(.minidiscCellTitle)
                                            .lineLimit(1)
                                        if let artist = display.artist {
                                            Text(artist)
                                                .font(.minidiscCellSubtitle)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        Text("\(display.downloadedTracksCount) tracks")
                                            .font(.minidiscCaption)
                                            .foregroundStyle(.tertiary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.vertical, MinidiscSpacing.xs)
                            }
                            .id(display.downloadScrollID)
                            .accessibilityIdentifier("downloads.album.\(display.albumId)")
                        }
                    }
                }

                if !orderedPlaylists.isEmpty {
                    Section("Playlists") {
                        ForEach(orderedPlaylists, id: \.downloadScrollID) { playlist in
                            NavigationLink(value: HomeDestination.playlistById(id: playlist.playlistId, name: playlist.name, coverArtId: playlist.coverArtId)) {
                                HStack(spacing: MinidiscSpacing.m) {
                                    CoverArtCard(id: playlist.coverArtId ?? playlist.playlistId, size: 56)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(playlist.name)
                                            .font(.minidiscCellTitle)
                                            .lineLimit(1)
                                        Text("\(playlist.tracksCount) tracks\(playlist.isComplete ? "" : " (incomplete)")")
                                            .font(.minidiscCaption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.vertical, MinidiscSpacing.xs)
                            }
                            .id(playlist.downloadScrollID)
                            .accessibilityIdentifier("downloads.playlist.\(playlist.playlistId)")
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }
}

// List must know the same IDs before offscreen rows are created. Giving only
// their child views prefixed anchors leaves those targets unresolved during a jump.
private extension DisplayableSong {
    var downloadScrollID: String { "song:\(id)" }
}

private extension DownloadedAlbumDisplay {
    var downloadScrollID: String { "album:\(id)" }
}

private extension DownloadedPlaylist {
    var downloadScrollID: String { "playlist:\(playlistId)" }
}
