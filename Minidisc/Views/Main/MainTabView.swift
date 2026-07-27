// Minidisc — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

struct MainTabView: View {
    @Environment(\.appContainer) private var container
    @Environment(\.colorScheme) private var colorScheme
    @State private var searchText = ""
    @State private var searchPath = NavigationPath()
    @State private var homePath = NavigationPath()
    @State private var selectedTab: AppTab = .home
    @State private var showingFullPlayer = false
    @Namespace private var playerZoom
    private let fullPlayerZoomID = "full-player"
    @AppStorage("minidisc.appTheme") private var theme: AppTheme = .system

    private enum AppTab: Hashable { case home, discover, library, lidarr, search }

    private var lidarrConnected: Bool { container?.lidarrSettings.isConnected == true }

    private var hasTrack: Bool {
        container?.playerState.currentTrack != nil || container?.playerState.isLiveStream == true
    }

    var body: some View {
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
            }
    }

    private var miniPlayer: some View {
        MiniPlayerAccessoryView(showingFullPlayer: $showingFullPlayer)
            .environment(\.colorScheme, colorScheme)
            .minidiscMatchedTransitionSource(id: fullPlayerZoomID, in: playerZoom)
    }

    private var tabs: some View {
        TabView(selection: $selectedTab) {
            Tab("Home", systemImage: "house.fill", value: AppTab.home) {
                NavigationStack(path: $homePath) {
                    HomeView()
                }
            }

            Tab("Discover", systemImage: "square.grid.2x2.fill", value: AppTab.discover) {
                NavigationStack {
                    DiscoverView()
                }
            }

            Tab("Library", systemImage: "music.note.square.stack.fill", value: AppTab.library) {
                NavigationStack {
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
                        .navigationBarTitleDisplayMode(.inline)
                }
                .searchable(text: $searchText, prompt: "Artists, albums, songs\u{2026}")
            }
        }
        .accentColor(.minidiscAccent)
        .preferredColorScheme(theme.colorScheme)

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
