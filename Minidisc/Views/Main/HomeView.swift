// Minidisc — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftSonic

/// Personalized Home feed: Top Picks (freshest playlists), Recently Played,
/// then one shelf per top library genre. The full library lives in the Library tab.
struct HomeView: View {
    @Environment(\.appContainer) private var container
    @Environment(ArtworkImageCache.self) private var artworkImageCache
    @State private var viewModel: HomeFeedViewModel?
    @State private var showSettings = false
    @Namespace private var homeZoomNamespace

    private var isOnline: Bool { container?.serverState.isOnline == true }

    var body: some View {
        Group {
            if !isOnline {
                EmptyStateView(
                    systemImage: "wifi.slash",
                    title: "You're Offline",
                    subtitle: "Your downloaded music lives in the Library tab."
                )
            } else if let vm = viewModel {
                content(vm)
            } else {
                LoadingStateView()
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .topTrailing) {
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(.title2)
                    .foregroundStyle(.primary)
                    .minidiscGlassButton(size: 44)
            }
            .buttonStyle(.plain)
            .padding(.trailing, MinidiscSpacing.l)
        }
        .sheet(isPresented: $showSettings) { SettingsSheet() }
        .navigationDestination(for: HomeDestination.self) { destination in
            resolve(destination)
        }
        .task(id: container?.serverState.isOnline) {
            guard let svc = container?.libraryService else { return }
            if viewModel == nil { viewModel = HomeFeedViewModel(libraryService: svc) }
            guard isOnline else { return }
            await viewModel?.load()
        }
    }

    // MARK: - Feed

    @ViewBuilder
    private func content(_ vm: HomeFeedViewModel) -> some View {
        if vm.isLoading && vm.isEmpty {
            LoadingStateView()
        } else if let error = vm.error, vm.isEmpty {
            EmptyStateView(
                systemImage: "exclamationmark.triangle",
                title: "Unable to Load",
                subtitle: LocalizedStringKey(error.displayMessage),
                action: .init(label: "Retry") { Task { await vm.load() } }
            )
        } else if vm.isEmpty {
            EmptyStateView(
                systemImage: "music.note.list",
                title: "No music yet",
                subtitle: "Add some music to your server to get started"
            )
        } else {
            ScrollView {
                // A plain VStack (not LazyVStack): the feed is a handful of shelves, so a deterministic
                // content height is cheap — and a LazyVStack's estimated height confuses the
                // pull-to-refresh inset math, stranding the ScrollView with a blank gap at the top.
                VStack(alignment: .leading, spacing: MinidiscSpacing.xxl) {
                    Text("Home")
                        .font(.largeTitle.bold())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, MinidiscSpacing.l)
                    if !vm.topPicks.isEmpty {
                        HomeShelf(title: "Top Picks for You") {
                            ForEach(vm.topPicks) { playlist in
                                TopPickCard(playlist: playlist, namespace: homeZoomNamespace)
                            }
                        }
                    }
                    if !vm.recentlyPlayed.isEmpty {
                        HomeShelf(title: "Recently Played") {
                            ForEach(vm.recentlyPlayed) { album in
                                HomeShelfAlbumCard(album: album)
                            }
                        }
                    }
                    if !vm.recentlyAdded.isEmpty {
                        HomeShelf(title: "Recently Added") {
                            ForEach(vm.recentlyAdded) { album in
                                HomeShelfAlbumCard(album: album)
                            }
                        }
                    }
                    ForEach(vm.genreShelves) { shelf in
                        HomeShelf(title: LocalizedStringKey(stringLiteral: shelf.name)) {
                            ForEach(shelf.albums) { album in
                                HomeShelfAlbumCard(album: album)
                            }
                        }
                    }
                }
                .padding(.top, MinidiscSpacing.m)
                .padding(.bottom, MinidiscSpacing.xl)
            }
            .refreshable { await vm.load() }
            .scrollEdgeEffectHidden(for: .top)
        }
    }

    // MARK: - Destination resolver

    @ViewBuilder
    private func resolve(_ destination: HomeDestination) -> some View {
        switch destination {
        case .libraryAlbums:
            AlbumsListView()
        case .libraryArtists:
            ArtistListView()
        case .librarySongs:
            SongsListView()
        case .libraryPlaylists:
            PlaylistListView()
        case .libraryFavorites:
            FavoritesView()
        case .libraryDownloads:
            DownloadedView()
        case .album(let album):
            AlbumDetailView(album: album)
        case .artist(let artist):
            ArtistDetailView(artist: artist)
        case .playlist(let playlist):
            PlaylistDetailView(
                playlist: playlist,
                coverArtId: playlist.coverArt ?? playlist.id,
                initialCoverImage: artworkImageCache.cachedImage(for: playlist.coverArt ?? playlist.id),
                zoomSourceId: playlist.id,
                zoomNamespace: homeZoomNamespace
            )
        case .downloadedAlbum(let display):
            AlbumDetailView(albumId: display.albumId, albumName: display.name, coverArtId: display.coverArtId, mode: .downloadedOnly)
        case .albumById(let id, let name, _, let coverArtId):
            AlbumDetailView(albumId: id, albumName: name, coverArtId: coverArtId)
        case .playlistById(let id, let name, let coverArtId):
            PlaylistDetailView(
                playlistId: id,
                name: name,
                coverArtId: coverArtId,
                initialCoverImage: artworkImageCache.cachedImage(for: coverArtId ?? id)
            )
        case .artistById(let id, let name, let coverArtId):
            ArtistDetailView(artist: ArtistID3(id: id, name: name, coverArt: coverArtId))
        case .artistBestOf(let id, let name, let coverArtId):
            ArtistBestOfView(artistId: id, artistName: name, coverArtId: coverArtId)
        case .offlineArtist(let artist):
            OfflineArtistAlbumsView(artist: artist)
        case .offlineAlbum(let album):
            AlbumDetailView(albumId: album.albumId, albumName: album.albumName, coverArtId: album.coverArtId)
        }
    }
}

// MARK: - Shelf container

/// A titled, edge-to-edge horizontal shelf with view-aligned paging.
private struct HomeShelf<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: MinidiscSpacing.s) {
            Text(title)
                .font(.minidiscShelfTitle)
                .padding(.horizontal, MinidiscSpacing.l)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: MinidiscSpacing.m) {
                    content()
                }
                .scrollTargetLayout()
                .padding(.horizontal, MinidiscSpacing.l)
            }
            .scrollTargetBehavior(.viewAligned)
        }
    }
}

// MARK: - Top pick card (large, Apple-Music style)

private struct TopPickCard: View {
    let playlist: Playlist
    let namespace: Namespace.ID

    private let side: CGFloat = 250

    var body: some View {
        NavigationLink(value: HomeDestination.playlist(playlist)) {
            VStack(alignment: .leading, spacing: MinidiscSpacing.s) {
                PlaylistCoverThumbnail(
                    playlistId: playlist.id,
                    serverId: nil,
                    coverArtId: playlist.coverArt ?? playlist.id,
                    title: playlist.name,
                    size: side
                )
                .minidiscMatchedTransitionSource(id: playlist.id, in: namespace)
                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.name)
                        .font(.minidiscCellTitle)
                        .lineLimit(1)
                    Text("\(playlist.songCount) tracks")
                        .font(.minidiscCaption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: side, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Shelf album card

private struct HomeShelfAlbumCard: View {
    let album: AlbumID3

    private let side: CGFloat = 160

    var body: some View {
        NavigationLink(value: HomeDestination.album(album)) {
            VStack(alignment: .leading, spacing: MinidiscSpacing.xs) {
                CoverArtView(id: album.coverArt ?? album.id, size: Int(side * 2))
                    .frame(width: side, height: side)
                    .minidiscCoverStyle(cornerRadius: MinidiscCornerRadius.standard)
                Text(album.name)
                    .font(.minidiscCaption)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                if let artist = album.artist {
                    Text(artist)
                        .font(.minidiscCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: side, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}
