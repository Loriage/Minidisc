import SwiftUI
import SwiftSonic

struct DiscoverView: View {
    @Environment(\.appContainer) private var container
    @State private var vm: DiscoverViewModel?
    @State private var loadedServerID: UUID?
    @State private var isStartingShuffle = false
    @State private var startingStationID: String?
    @State private var yearlyPlaylists: [WrappedYearlyPlaylist] = []
    @State private var radioStations: [InternetRadioStation] = []
    @Namespace private var freshReleaseZoomNamespace
    @State private var showAllFreshReleases = false
    @State private var allReleasesVM: AllFreshReleasesViewModel?
    @State private var isListenBrainzConnected: Bool = false
    @State private var availableMoods: [MoodPlaylist] = []
    @State private var moodReloadID = 0

    private var isOnline: Bool { container?.serverState.isOnline == true }
    private var visibleMoods: [MoodPlaylist] {
        guard !isOnline else { return availableMoods }
        return (container?.offlineLibrary.snapshot.playlists ?? []).compactMap { playlist in
            guard let mood = Mood.allCases.first(where: { $0.playlistName == playlist.name }) else { return nil }
            return MoodPlaylist(mood: mood, id: playlist.id, coverArtId: playlist.coverArt)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: MinidiscSpacing.xxl) {
                if let vm {
                    if isOnline {
                        freshReleasesSection(vm: vm)
                        stationsSection(vm)
                    }
                    if isOnline || container?.offlineLibrary.snapshot.songs.isEmpty == false {
                        SmartShuffleCard(coverIDs: shuffleCoverIDs(vm), isStarting: isStartingShuffle) {
                            Task { await triggerSmartShuffle() }
                        }
                    }
                    moodsSection
                    wrappedSection
                    if isOnline { internetRadioSection }
                }
            }
            .padding(.top, MinidiscSpacing.m)
            .padding(.bottom, MinidiscSpacing.miniPlayerBottomMargin)
        }
        .navigationTitle("Discover")
        .toolbarTitleDisplayMode(.inlineLarge)
        .minidiscContentWidth()
        .task(id: container?.serverState.accessSnapshot) {
            guard let container else { return }
            let serverID = container.serverState.activeServer?.id
            if vm == nil || loadedServerID != serverID {
                loadedServerID = serverID
                vm = DiscoverViewModel(libraryService: container.libraryService,
                                       recommendationService: container.recommendationService)
                allReleasesVM = AllFreshReleasesViewModel(recommendationService: container.recommendationService)
                radioStations = []
                yearlyPlaylists = []
                availableMoods = []
                isListenBrainzConnected = false
            }
            if isOnline { await refreshDiscover(forceRefresh: false) }
            else if let serverID { await loadMoodPlaylists(serverId: serverID.uuidString) }
        }
        .refreshable { await refreshDiscover(forceRefresh: true) }
        .onReceive(NotificationCenter.default.publisher(for: .minidiscMoodPlaylistsChanged)) { _ in
            moodReloadID += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .minidiscPlaylistsChanged)) { _ in
            moodReloadID += 1
        }
        .task(id: moodReloadID) {
            guard let serverId = container?.serverState.activeServer?.id.uuidString else { return }
            await loadMoodPlaylists(serverId: serverId)
        }
        .navigationDestination(for: AlbumRecommendation.self) { release in
            FreshReleaseDetailView(
                release: release,
                providers: container?.externalProvidersStore.load() ?? []
            )
            .minidiscZoomTransition(
                sourceID: release.id ?? "\(release.artistName)-\(release.title)",
                in: freshReleaseZoomNamespace
            )
        }
        .navigationDestination(isPresented: $showAllFreshReleases) {
            if let allReleasesVM {
                AllFreshReleasesView(vm: allReleasesVM)
            }
        }
    }

    // MARK: - Moods

    @ViewBuilder
    private var moodsSection: some View {
        if !visibleMoods.isEmpty {
            VStack(alignment: .leading, spacing: MinidiscSpacing.s) {
                Text("Moods")
                    .font(.minidiscShelfTitle)
                    .padding(.horizontal, MinidiscSpacing.l)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: MinidiscSpacing.s) {
                        ForEach(visibleMoods, id: \.mood) { entry in
                            MoodCard(mood: entry.mood, playlistId: entry.id, coverArtId: entry.coverArtId)
                        }
                    }
                    .padding(.horizontal, MinidiscSpacing.l)
                }
            }
        }
    }

    /// Await sync before reading the playlists, including the first run that creates them.
    private func refreshMoods(serverId: String) async {
        guard let service = container?.moodPlaylistService else { return }
        _ = await BackgroundActivity.run("mood-playlists") {
            await service.runWeeklySyncIfNeeded(serverId: serverId)
        }
        await loadMoodPlaylists(serverId: serverId)
    }

    private func loadMoodPlaylists(serverId: String) async {
        guard let service = container?.moodPlaylistService else { return }
        if !isOnline {
            availableMoods = await service.cachedPlaylists(serverId: serverId)
            return
        }
        let found: [MoodPlaylist]
        do {
            found = try await service.fetchPlaylists(serverId: serverId)
        } catch is CancellationError {
            return
        } catch {
            // Keep offline navigation on a cold launch without discarding a previously loaded cover.
            guard availableMoods.isEmpty else { return }
            found = await service.cachedPlaylists(serverId: serverId)
        }
        guard !Task.isCancelled,
              container?.serverState.activeServer?.id.uuidString == serverId else { return }
        availableMoods = found
    }

    // MARK: - Sections

    @ViewBuilder
    private func freshReleasesSection(vm: DiscoverViewModel) -> some View {
        if isListenBrainzConnected, !vm.freshReleases.isEmpty {
            FreshReleasesCard(
                releases: vm.freshReleases,
                isLoading: false,
                isListenBrainzConnected: isListenBrainzConnected,
                onSeeAll: { showAllFreshReleases = true },
                zoomNamespace: freshReleaseZoomNamespace
            )
            .accessibilityIdentifier("discover.freshReleases")
        }
    }

    @ViewBuilder
    private func stationsSection(_ vm: DiscoverViewModel) -> some View {
        if !vm.stations.isEmpty {
            MinidiscShelf {
                MinidiscCarouselHeader("Stations for You", showsChevron: false)
                    .accessibilityIdentifier("discover.stations")
            } content: {
                ForEach(vm.stations) { station in
                    ArtistStationCard(station: station, isStarting: startingStationID == station.id) {
                        Task { await playStation(station) }
                    }
                }
            }
        }
    }

    private func shuffleCoverIDs(_ vm: DiscoverViewModel) -> [String] {
        var seen = Set<String>()
        let albums = isOnline ? vm.recentlyPlayed + vm.mostPlayed : container?.offlineLibrary.snapshot.albums ?? []
        return albums.map { $0.coverArt ?? $0.id }
            .filter { seen.insert($0).inserted }.prefix(3).map { $0 }
    }

    private func playStation(_ station: ArtistStation) async {
        guard let container else { return }
        startingStationID = station.id
        HapticFeedback.medium.trigger()
        defer { if startingStationID == station.id { startingStationID = nil } }
        await container.toastService.perform {
            try await container.playerService.playInstantMix(from: .artist(id: station.id), startingWith: station.starter)
        }
    }

    private func refreshDiscover(forceRefresh: Bool) async {
        guard let vm, isOnline else { return }
        async let personal: Void = vm.load(forceRefresh: forceRefresh)
        async let releases: Void = refreshFreshReleases(vm)
        async let radio: Void = loadRadioStations(forceRefresh: forceRefresh)
        async let mixes: Void = refreshServerMixes()
        _ = await (personal, releases, radio, mixes)
    }

    private func refreshFreshReleases(_ model: DiscoverViewModel) async {
        guard let container else { return }
        let connected = await container.listenBrainzService.currentSnapshot().isEnabled
        guard !Task.isCancelled else { return }
        isListenBrainzConnected = connected
        if connected { await model.loadFreshReleases() }
    }

    private func refreshServerMixes() async {
        guard let container, let serverID = container.serverState.activeServer?.id.uuidString else { return }
        let playlists = await container.wrappedPlaylistService.fetchYearlyPlaylists(serverId: serverID)
        guard !Task.isCancelled else { return }
        yearlyPlaylists = playlists
        await refreshMoods(serverId: serverID)
    }

    private func triggerSmartShuffle() async {
        guard let container, !isStartingShuffle else { return }
        isStartingShuffle = true
        HapticFeedback.medium.trigger()
        defer { isStartingShuffle = false }
        do {
            try await container.playerService.playSmartShuffle()
        } catch {
            if !UserFacingError.isCancellation(error) {
                container.toastService.showError(smartShuffleErrorMessage(from: error))
            }
        }
    }

    private func smartShuffleErrorMessage(from error: Error) -> String {
        if case MinidiscError.smartShuffleEmpty = error {
            return String(localized: "Smart Shuffle unavailable — try playing some tracks first or download more music for offline use.")
        }
        return String(localized: "Smart Shuffle failed. Please try again.")
    }

    private var wrappedSection: some View {
        VStack(alignment: .leading, spacing: MinidiscSpacing.s) {
            MinidiscCarouselHeaderLink(
                "Wrapped",
                itemCount: wrappedItems.count,
                hasMore: true
            ) {
                WrappedYearlyListView()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: MinidiscSpacing.s) {
                    ForEach(Array(wrappedItems.prefix(MinidiscCarouselMetrics.previewLimit))) { item in
                        switch item {
                        case .yearly(let playlist):
                            WrappedYearlyCard(playlist: playlist)
                        case .currentYear(let year):
                            WrappedCurrentYearCard(year: year)
                        case .month(let year, let month):
                            WrappedRecapMonthCard(period: .month(year: year, month: month))
                        }
                    }
                }
                .padding(.horizontal, MinidiscSpacing.l)
            }
        }
    }

    private var wrappedItems: [WrappedCarouselItem] {
        let playlists = isOnline ? yearlyPlaylists : (container?.offlineLibrary.snapshot.playlists ?? []).compactMap { playlist -> WrappedYearlyPlaylist? in
            let prefix = WrappedPlaylistService.wrappedPlaylistNamePrefix
            guard playlist.name.hasPrefix(prefix), let year = Int(playlist.name.dropFirst(prefix.count)) else { return nil }
            return WrappedYearlyPlaylist(id: playlist.id, year: year, name: playlist.name, coverArtId: playlist.coverArt)
        }
        var items = playlists.map(WrappedCarouselItem.yearly)
        let year = Calendar.current.component(.year, from: Date())
        if !playlists.contains(where: { $0.year == year }) {
            items.append(.currentYear(year))
        }
        items.append(contentsOf: currentYearMonths.map {
            .month(year: $0.year, month: $0.month)
        })
        return items
    }

    private var currentYearMonths: [(year: Int, month: Int)] {
        let cal = Calendar.current
        let now = Date()
        let year = cal.component(.year, from: now)
        let currentMonth = cal.component(.month, from: now)
        return (1...currentMonth).reversed().map { (year, $0) }
    }

    private var internetRadioSection: some View {
        VStack(alignment: .leading, spacing: MinidiscSpacing.s) {
            MinidiscCarouselHeaderLink(
                "Internet Radio",
                itemCount: radioStations.count,
                hasMore: true
            ) {
                RadioListView()
            }

            if radioStations.isEmpty {
                NavigationLink {
                    RadioListView()
                } label: {
                    HStack(spacing: MinidiscSpacing.s) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.title2)
                            .foregroundStyle(Color.minidiscAccent)
                        Text("Browse Stations")
                            .font(.minidiscCellTitle)
                            .foregroundStyle(.primary)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(MinidiscSpacing.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.minidiscAccent.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: MinidiscCornerRadius.standard, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, MinidiscSpacing.l)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: MinidiscSpacing.s) {
                        ForEach(
                            Array(radioStations.prefix(MinidiscCarouselMetrics.previewLimit)),
                            id: \.id
                        ) { station in
                            RadioCard(station: station)
                        }
                    }
                    .padding(.horizontal, MinidiscSpacing.l)
                }
            }
        }
    }

    private func loadRadioStations(forceRefresh: Bool) async {
        guard let radioService = container?.radioService else { return }
        if let stations = try? await radioService.listStations(forceRefresh: forceRefresh) {
            guard !Task.isCancelled else { return }
            radioStations = stations
        }
    }

}

private enum WrappedCarouselItem: Identifiable {
    case yearly(WrappedYearlyPlaylist)
    case currentYear(Int)
    case month(year: Int, month: Int)

    var id: String {
        switch self {
        case .yearly(let playlist):
            "yearly-\(playlist.id)"
        case .currentYear(let year):
            "current-\(year)"
        case .month(let year, let month):
            "month-\(year)-\(month)"
        }
    }
}
