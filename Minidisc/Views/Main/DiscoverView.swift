// Minidisc — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftSonic

struct DiscoverView: View {
    @Environment(\.appContainer) private var container
    @Environment(ArtworkImageCache.self) private var artworkImageCache
    @State private var vm: DiscoverViewModel?
    @Namespace private var recentlyPlayedNS
    @Namespace private var mostPlayedNS
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
                Text("Discover")
                    .font(.largeTitle.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, MinidiscSpacing.l)
                if let vm {
                    if vm.isErrorState {
                        errorBanner(vm: vm)
                    } else {
                        freshReleasesSection(vm: vm)
                        recentlyPlayedSection(vm: vm)
                        mostPlayedSection(vm: vm)
                    }
                    smartShuffleSection
                    moodsSection
                    wrappedSection
                    internetRadioSection
                }
            }
            .padding(.vertical, MinidiscSpacing.m)
        }
        .scrollEdgeEffectHidden(for: .top)
        .minidiscContentWidth()
        .task {
            guard let container else { return }
            if vm == nil {
                vm = DiscoverViewModel(
                    libraryService: container.libraryService,
                    recommendationService: container.recommendationService
                )
            }
            if allReleasesVM == nil {
                allReleasesVM = AllFreshReleasesViewModel(recommendationService: container.recommendationService)
            }
            await vm?.load()
            isListenBrainzConnected = await container.listenBrainzService.currentSnapshot().isEnabled
            await vm?.loadFreshReleases()
            radioStations = (try? await container.radioService.listStations(forceRefresh: false)) ?? []
            guard let serverId = container.serverState.activeServer?.id.uuidString else { return }
            yearlyPlaylists = await container.wrappedPlaylistService.fetchYearlyPlaylists(serverId: serverId)
            await refreshMoods(serverId: serverId)
        }
        .refreshable {
            await vm?.load(forceRefresh: true)
            isListenBrainzConnected = await container?.listenBrainzService.currentSnapshot().isEnabled ?? false
            await vm?.loadFreshReleases()
            radioStations = (try? await container?.radioService.listStations(forceRefresh: true)) ?? []
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
            if let vm = allReleasesVM {
                AllFreshReleasesView(vm: vm)
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
        availableMoods = found
    }

    // MARK: - Sections

    // Hidden entirely when ListenBrainz is not connected — no "connect in Settings" teaser.
    @ViewBuilder
    private func freshReleasesSection(vm: DiscoverViewModel) -> some View {
        if isListenBrainzConnected {
            FreshReleasesCard(
                releases: vm.freshReleases,
                isLoading: vm.isLoadingFreshReleases,
                isListenBrainzConnected: isListenBrainzConnected,
                onSeeAll: { showAllFreshReleases = true },
                zoomNamespace: freshReleaseZoomNamespace
            )
        }
    }

    private func recentlyPlayedSection(vm: DiscoverViewModel) -> some View {
        section(title: "Recently Played") {
            if vm.isInitialLoading {
                skeletonScroll()
            } else if vm.recentlyPlayed.isEmpty {
                emptyStateMessage("No history yet — start playing some tracks.")
            } else {
                horizontalAlbumScroll(albums: vm.recentlyPlayed, namespace: recentlyPlayedNS)
            }
        }
    }

    private func mostPlayedSection(vm: DiscoverViewModel) -> some View {
        section(title: "Most Played") {
            if vm.isInitialLoading {
                skeletonScroll()
            } else if vm.mostPlayed.isEmpty {
                emptyStateMessage("No frequent plays yet — your top tracks will appear here.")
            } else {
                horizontalAlbumScroll(albums: vm.mostPlayed, namespace: mostPlayedNS)
            }
        }
    }

    private var smartShuffleSection: some View {
        section(title: "Smart Shuffle") {
            Button {
                Task { await triggerSmartShuffle() }
            } label: {
                HStack(spacing: MinidiscSpacing.s) {
                    Image(systemName: "shuffle.circle.fill")
                        .font(.title2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Rediscover Your Library")
                            .font(.minidiscCellTitle)
                        Text("A random mix from your library")
                            .font(.minidiscCaption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(MinidiscSpacing.l)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.minidiscAccent.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: MinidiscCornerRadius.standard, style: .continuous))
                .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, MinidiscSpacing.l)
        }
    }

    private func triggerSmartShuffle() async {
        guard let container else { return }
        do {
            try await container.playerService.playSmartShuffle()
        } catch {
            container.toastService.showError(smartShuffleErrorMessage(from: error))
        }
    }

    private func smartShuffleErrorMessage(from error: Error) -> String {
        if case MinidiscError.smartShuffleEmpty = error {
            return "Smart Shuffle unavailable — try playing some tracks first or download more music for offline use."
        }
        return "Smart Shuffle failed. Please try again."
    }

    private var wrappedSection: some View {
        VStack(alignment: .leading, spacing: MinidiscSpacing.s) {
            HStack {
                Text("Wrapped")
                    .font(.minidiscShelfTitle)
                Spacer(minLength: 0)
                NavigationLink {
                    WrappedYearlyListView()
                } label: {
                    Text("See all")
                        .font(.minidiscCaption)
                        .foregroundStyle(Color.minidiscAccent)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, MinidiscSpacing.l)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: MinidiscSpacing.s) {
                    ForEach(yearlyPlaylists) { playlist in
                        WrappedYearlyCard(playlist: playlist)
                    }
                    if let year = currentYearCardYear {
                        WrappedCurrentYearCard(year: year)
                    }
                    ForEach(currentYearMonths, id: \.month) { item in
                        WrappedRecapMonthCard(period: .month(year: item.year, month: item.month))
                    }
                }
                .padding(.horizontal, MinidiscSpacing.l)
            }
        }
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
            HStack {
                Text("Internet Radio")
                    .font(.minidiscShelfTitle)
                Spacer(minLength: 0)
                NavigationLink {
                    RadioListView()
                } label: {
                    Text("See all")
                        .font(.minidiscCaption)
                        .foregroundStyle(Color.minidiscAccent)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, MinidiscSpacing.l)

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
                        ForEach(radioStations, id: \.id) { station in
                            RadioCard(station: station)
                        }
                    }
                    .padding(.horizontal, MinidiscSpacing.l)
                }
            }
        }
    }

    // MARK: - Helpers

    private func section<Content: View>(title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: MinidiscSpacing.s) {
            Text(title)
                .font(.minidiscShelfTitle)
                .padding(.horizontal, MinidiscSpacing.l)
            content()
        }
    }

    private func horizontalAlbumScroll(albums: [AlbumID3], namespace: Namespace.ID) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: MinidiscSpacing.s) {
                ForEach(albums, id: \.id) { album in
                    NavigationLink {
                        AlbumDetailView(
                            album: album,
                            zoomSourceId: album.id,
                            zoomNamespace: namespace,
                            initialCoverImage: artworkImageCache.cachedImage(for: album.coverArt ?? album.id)
                        )
                    } label: {
                        AlbumCard(album: album)
                            .minidiscMatchedTransitionSource(id: album.id, in: namespace)
                            .task(id: album.id) {
                                await artworkImageCache.load(coverArtId: album.coverArt ?? album.id)
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, MinidiscSpacing.l)
        }
    }

    private func errorBanner(vm: DiscoverViewModel) -> some View {
        VStack(alignment: .leading, spacing: MinidiscSpacing.s) {
            HStack(spacing: MinidiscSpacing.s) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow) // warning state — not brand accent
                Text("Unable to load Discover")
                    .font(.minidiscCellTitle)
            }
            if let message = vm.loadError?.localizedDescription {
                Text(message)
                    .font(.minidiscCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Button {
                Task { await vm.load(forceRefresh: true) }
            } label: {
                Text("Retry")
                    .font(.minidiscCellTitle)
                    .padding(.horizontal, MinidiscSpacing.l)
                    .padding(.vertical, MinidiscSpacing.s)
                    .background(Color.minidiscAccent)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: MinidiscCornerRadius.standard, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(MinidiscSpacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yellow.opacity(0.12)) // warning state — not brand accent
        .clipShape(RoundedRectangle(cornerRadius: MinidiscCornerRadius.standard, style: .continuous))
        .padding(.horizontal, MinidiscSpacing.l)
    }

    private func skeletonScroll() -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: MinidiscSpacing.s) {
                ForEach(0..<6, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: MinidiscSpacing.xs) {
                        SkeletonBlock(width: 140, height: 140, cornerRadius: MinidiscCornerRadius.standard)
                        SkeletonBlock(width: 110, height: 12)
                        SkeletonBlock(width: 80, height: 10)
                    }
                    .frame(width: 140)
                }
            }
            .padding(.horizontal, MinidiscSpacing.l)
        }
        .allowsHitTesting(false)
    }

    private func emptyStateMessage(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.minidiscCaption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, MinidiscSpacing.l)
            .padding(.horizontal, MinidiscSpacing.l)
    }
}
