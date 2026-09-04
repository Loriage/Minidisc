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
        ScrollViewReader { proxy in
            List {
                DownloadActivitySection(serverID: serverId)
                if !standaloneSongs.isEmpty {
                    Section("Songs") {
                        ForEach(standaloneSongs) { song in
                            Button {
                                let songs = standaloneSongs
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
                if !displayAlbums.isEmpty {
                    Section("Albums") {
                        ForEach(displayAlbums) { display in
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
                            .id(display.id)
                        }
                    }
                }

                if !playlists.isEmpty {
                    Section("Playlists") {
                        ForEach(playlists) { playlist in
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
                        }
                    }
                }
            }
            .listStyle(.plain)
            .safeAreaInset(edge: .trailing, spacing: 0) {
                if displayAlbums.count >= 20 {
                    AlphabetJumpBar(
                        availableLetters: displayAlbums.availableAlphabetLetters(keyPath: \.name),
                        onLetterTap: { letter in
                            if let id = firstAlphabetItemID(forLetter: letter, in: displayAlbums, keyPath: \.name) {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    proxy.scrollTo(id, anchor: .top)
                                }
                            }
                        }
                    )
                    .padding(.trailing, 4)
                }
            }
        }
    }
}
