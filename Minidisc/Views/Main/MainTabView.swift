import SwiftUI

struct MainTabView: View {
    @Environment(\.appContainer) private var container
    @SceneStorage("minidisc.searchText") private var searchText = ""
    @State private var searchPath = NavigationPath()
    @State private var homePath = NavigationPath()
    @State private var libraryPath = NavigationPath()
    @State private var discoverPath = NavigationPath()
    @SceneStorage("minidisc.selectedTab") private var selectedTab: AppTab = .home
    @State private var playerPresentation = PlayerContainerConfiguration()
    @State private var albumNavigation = PlayerAlbumNavigation()
    @State private var playlistAddition = PlaylistAddition()
    @AppStorage("minidisc.appTheme") private var theme: AppTheme = .system

    private typealias AppTab = PlayerAlbumNavigation.Tab

    private var lidarrConnected: Bool { container?.lidarrSettings.isConnected == true }

    private var hasTrack: Bool {
        container?.playerState.currentTrack != nil || container?.playerState.isLiveStream == true
    }

    var body: some View {
        @Bindable var playlistAddition = playlistAddition

        tabs
            .accessibilityHidden(playerPresentation.attachExpandedPlayer)
            .overlay(alignment: .topLeading) {
                if playerPresentation.attachExpandedPlayer {
                    PlayerContainer(configuration: playerPresentation)
                        .transition(.identity)
                }
            }
            .tabViewBottomAccessory(isEnabled: hasTrack && !playerPresentation.attachExpandedPlayer) {
                PlayerContainer(configuration: playerPresentation)
            }
            .tabBarMinimizeBehavior(.onScrollDown)
            .onChange(of: hasTrack) { _, hasTrack in
                if !hasTrack { playerPresentation.reset() }
            }
            .sheet(item: $playlistAddition.request) { request in
                AddToPlaylistSheet(request: request)
            }
            .environment(playlistAddition)
    }

    private var tabs: some View {
        TabView(selection: $selectedTab) {
            if container?.serverState.activeServer != nil {
                Tab("Home", image: "HomeTabIcon", value: AppTab.home) {
                    NavigationStack(path: $homePath) {
                        HomeView()
                            .playerAlbumDestinations()
                    }
                    .environment(\.albumNavigationContext, AlbumNavigationContext(navigation: albumNavigation, tab: .home))
                }

                Tab("Discover", systemImage: "square.grid.2x2.fill", value: AppTab.discover) {
                    NavigationStack(path: $discoverPath) {
                        DiscoverView()
                            .playerAlbumDestinations()
                    }
                    .environment(\.albumNavigationContext, AlbumNavigationContext(navigation: albumNavigation, tab: .discover))
                }

            }

            Tab("Library", systemImage: "music.note.square.stack.fill", value: AppTab.library) {
                NavigationStack(path: $libraryPath) {
                    if container?.serverState.activeServer == nil { LocalMusicView() }
                    else { LibraryView().playerAlbumDestinations() }
                }
                .environment(\.albumNavigationContext, AlbumNavigationContext(navigation: albumNavigation, tab: .library))
            }

            if lidarrConnected {
                Tab("Lidarr", systemImage: "opticaldisc.fill", value: AppTab.lidarr) {
                    NavigationStack {
                        LidarrLibraryView()
                    }
                }
            }

            // Bare `Tab(value:role:)`: the search role renders its own detached button, glyph and
            // label. Passing a title and systemImage here draws a second glyph over the system's.
            if container?.serverState.activeServer != nil {
                Tab(value: AppTab.search, role: .search) {
                    NavigationStack(path: $searchPath) {
                        SearchView(searchQuery: $searchText, path: $searchPath)
                            .playerAlbumDestinations()
                            .navigationTitle("Search")
                            .toolbarTitleDisplayMode(.inlineLarge)
                    }
                    .environment(\.albumNavigationContext, AlbumNavigationContext(navigation: albumNavigation, tab: .search))
                    .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always),
                                prompt: "Artists, albums, songs, playlists…")
                }
            }
        }
        .onAppear { if container?.serverState.activeServer == nil { selectedTab = .library } }
        .accentColor(.minidiscAccent)
        .preferredColorScheme(theme.colorScheme)
        .onChange(of: container?.serverState.activeServer?.id) {
            albumNavigation.reset()
            homePath = NavigationPath()
            libraryPath = NavigationPath()
            discoverPath = NavigationPath()
            searchPath = NavigationPath()
            searchText = ""
        }
        .onChange(of: lidarrConnected, initial: true) {
            if !lidarrConnected, selectedTab == .lidarr { selectedTab = .home }
        }
        .onReceive(NotificationCenter.default.publisher(for: .minidiscNavigateToLibrary)) { _ in
            playerPresentation.reset()
            libraryPath = NavigationPath()
            selectedTab = .library
        }
        .onReceive(NotificationCenter.default.publisher(for: .minidiscNavigateToDownloads)) { _ in
            playerPresentation.reset()
            libraryPath = NavigationPath([HomeDestination.libraryDownloads])
            selectedTab = .library
        }

        .task(id: container?.serverState.accessSnapshot) {
            guard container?.serverState.isOnline == true else { return }
            try? await container?.favoritesService.syncFromServer()
        }
        .onReceive(NotificationCenter.default.publisher(for: .minidiscNavigateToArtist)) { note in
            guard let id   = note.userInfo?["artistId"]   as? String,
                  let name = note.userInfo?["artistName"] as? String else { return }
            let coverArtId = note.userInfo?["coverArtId"] as? String
            playerPresentation.reset()
            selectedTab = .home
            homePath.append(HomeDestination.artistById(id: id, name: name, coverArtId: coverArtId))
        }
        .onReceive(NotificationCenter.default.publisher(for: .minidiscNavigateToAlbum)) { note in
            guard let album = note.object as? PlayerAlbumDestination,
                  let action = albumNavigation.action(for: album, from: selectedTab,
                                                      activeServerID: container?.serverState.activeServer?.id) else { return }
            playerPresentation.reset()
            switch action {
            case .reveal(let tab):
                selectedTab = tab
            case .push(let tab):
                selectedTab = tab
                switch tab {
                case .home: homePath.append(album)
                case .discover: discoverPath.append(album)
                case .library: libraryPath.append(album)
                case .search: searchPath.append(album)
                case .lidarr: break // Lidarr resolves to Home before reaching this point.
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .minidiscNavigateToPlaylist)) { note in
            guard let id   = note.userInfo?["playlistId"] as? String,
                  let name = note.userInfo?["name"]       as? String else { return }
            let coverArtId = note.userInfo?["coverArtId"] as? String
            playerPresentation.reset()
            selectedTab = .home
            homePath.append(HomeDestination.playlistById(id: id, name: name, coverArtId: coverArtId))
        }
    }
}
