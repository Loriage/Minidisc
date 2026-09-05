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
    /// Moods that have a server playlist to open. Empty when AudioMuse is unconfigured or has
    /// never completed a sync — the section then disappears entirely rather than showing dead tiles.
    @State private var availableMoods: [(mood: Mood, playlistId: String)] = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: MinidiscSpacing.xxl) {
                if let vm {
                    freshReleasesSection(vm: vm)
                    stationsSection(vm)
                    SmartShuffleCard(coverIDs: shuffleCoverIDs(vm), isStarting: isStartingShuffle) {
                        Task { await triggerSmartShuffle() }
                    }
                    moodsSection
                    wrappedSection
                    internetRadioSection
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
            await refreshDiscover(forceRefresh: false)
        }
        .refreshable { await refreshDiscover(forceRefresh: true) }
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
        if !availableMoods.isEmpty {
            VStack(alignment: .leading, spacing: MinidiscSpacing.s) {
                Text("Moods")
                    .font(.minidiscShelfTitle)
                    .padding(.horizontal, MinidiscSpacing.l)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: MinidiscSpacing.s) {
                        ForEach(availableMoods, id: \.mood) { entry in
                            MoodCard(mood: entry.mood, playlistId: entry.playlistId)
                        }
                    }
                    .padding(.horizontal, MinidiscSpacing.l)
                }
            }
        }
    }

    /// Runs the weekly sync if it is due, then reads back whichever moods now have a playlist.
    ///
    /// Deliberately awaited inside the screen's own task rather than fired and forgotten: the sync
    /// is a no-op on all but one launch a week, and on that launch the section should populate
    /// before the user scrolls past it.
    private func refreshMoods(serverId: String) async {
        guard let service = container?.moodPlaylistService else { return }
        _ = await BackgroundActivity.run("mood-playlists") {
            await service.runWeeklySyncIfNeeded(serverId: serverId)
        }
        var found: [(mood: Mood, playlistId: String)] = []
        for mood in Mood.allCases {
            if let id = await service.playlistId(for: mood, serverId: serverId) {
                found.append((mood, id))
            }
        }
        guard !Task.isCancelled else { return }
        availableMoods = found
    }

    // MARK: - Sections

    // Hidden entirely when ListenBrainz is not connected — no "connect in Settings" teaser.
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
        return (vm.recentlyPlayed + vm.mostPlayed).map { $0.coverArt ?? $0.id }
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
        guard let vm else { return }
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
        var items = yearlyPlaylists.map(WrappedCarouselItem.yearly)
        if let year = currentYearCardYear {
            items.append(.currentYear(year))
        }
        items.append(contentsOf: currentYearMonths.map {
            .month(year: $0.year, month: $0.month)
        })
        return items
    }

    private var currentYearCardYear: Int? {
        let year = Calendar.current.component(.year, from: Date())
        guard !yearlyPlaylists.contains(where: { $0.year == year }) else { return nil }
        return year
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
