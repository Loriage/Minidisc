import SwiftUI

struct MainTabView: View {
    @Environment(\.appContainer) private var container
    @SceneStorage("minidisc.searchText") private var searchText = ""
    @State private var searchPath = NavigationPath()
    @State private var homePath = NavigationPath()
    @State private var libraryPath = NavigationPath()
    @State private var discoverPath = NavigationPath()
    @SceneStorage("minidisc.selectedTab") private var selectedTab: AppTab = .home
    @State private var showingFullPlayer = false
    @State private var playlistAddition = PlaylistAddition()
    @Namespace private var playerZoom
    @AppStorage("minidisc.appTheme") private var theme: AppTheme = .system

    private enum AppTab: String, Hashable { case home, discover, library, lidarr, search }
    private let fullPlayerZoomID = "full-player"

    private var lidarrConnected: Bool { container?.lidarrSettings.isConnected == true }

    private var hasTrack: Bool {
        container?.playerState.currentTrack != nil || container?.playerState.isLiveStream == true
    }

    var body: some View {
        @Bindable var playlistAddition = playlistAddition

        tabs
            .tabBarMinimizeBehavior(.onScrollDown)
            // isEnabled at the modifier level — a conditional INSIDE the accessory builder
            // still renders an empty glass capsule when nothing plays.
            .tabViewBottomAccessory(isEnabled: hasTrack) {
                miniPlayer
            }
            .fullScreenCover(isPresented: $showingFullPlayer) {
                FullPlayerView()
                    .minidiscZoomTransition(sourceID: fullPlayerZoomID, in: playerZoom)
                    .toastOverlay(reservesMiniPlayerSpace: false)
            }
            .sheet(item: $playlistAddition.request) { request in
                AddToPlaylistSheet(request: request)
            }
            .environment(playlistAddition)
    }

    // The accessory deliberately inherits the colour scheme the system gives its glass container instead of
    // being pinned to the app's: the system flips that glass light or dark against whatever is behind it (a
    // very dark page gets LIGHT glass), and the tab bar's own labels follow it. Pinning the app appearance
    // here is what left the mini player's labels black on a dark playlist while the tab items went white.
    private var miniPlayer: some View {
        MiniPlayerAccessoryView(showingFullPlayer: $showingFullPlayer)
            .minidiscMatchedTransitionSource(id: fullPlayerZoomID, in: playerZoom)
    }

    private var tabs: some View {
        TabView(selection: $selectedTab) {
            Tab("Home", image: "HomeTabIcon", value: AppTab.home) {
                NavigationStack(path: $homePath) {
                    HomeView()
                }
            }

            Tab("Discover", systemImage: "square.grid.2x2.fill", value: AppTab.discover) {
                NavigationStack(path: $discoverPath) {
                    DiscoverView()
                }
            }

            Tab("Library", systemImage: "music.note.square.stack.fill", value: AppTab.library) {
                NavigationStack(path: $libraryPath) {
                    LibraryView()
                }
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
            Tab(value: AppTab.search, role: .search) {
                NavigationStack(path: $searchPath) {
                    SearchView(searchQuery: $searchText, path: $searchPath)
                        .navigationTitle("Search")
                        .toolbarTitleDisplayMode(.inlineLarge)
                }
                .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always),
                            prompt: "Artists, albums, songs, playlists…")
            }
        }
        .accentColor(.minidiscAccent)
        .preferredColorScheme(theme.colorScheme)
        .onChange(of: container?.serverState.activeServer?.id) {
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
            showingFullPlayer = false
            libraryPath = NavigationPath()
            selectedTab = .library
        }
        .onReceive(NotificationCenter.default.publisher(for: .minidiscNavigateToDownloads)) { _ in
            showingFullPlayer = false
            libraryPath = NavigationPath([HomeDestination.libraryDownloads])
            selectedTab = .library
        }

        .task(id: container?.serverState.isOnline) {
            guard container?.serverState.isOnline == true else { return }
            try? await container?.favoritesService.syncFromServer()
        }
        .onReceive(NotificationCenter.default.publisher(for: .minidiscNavigateToArtist)) { note in
            guard let id   = note.userInfo?["artistId"]   as? String,
                  let name = note.userInfo?["artistName"] as? String else { return }
            let coverArtId = note.userInfo?["coverArtId"] as? String
            showingFullPlayer = false
            selectedTab = .home
            homePath.append(HomeDestination.artistById(id: id, name: name, coverArtId: coverArtId))
        }
        .onReceive(NotificationCenter.default.publisher(for: .minidiscNavigateToPlaylist)) { note in
            guard let id   = note.userInfo?["playlistId"] as? String,
                  let name = note.userInfo?["name"]       as? String else { return }
            let coverArtId = note.userInfo?["coverArtId"] as? String
            showingFullPlayer = false
            selectedTab = .home
            homePath.append(HomeDestination.playlistById(id: id, name: name, coverArtId: coverArtId))
        }
    }
}
