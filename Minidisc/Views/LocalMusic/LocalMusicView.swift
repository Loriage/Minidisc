import SwiftUI

nonisolated enum LocalMusicCategory: String, CaseIterable, Identifiable {
    case albums, artists, songs
    var id: String { rawValue }
    var title: LocalizedStringResource {
        switch self {
        case .albums: "Albums"
        case .artists: "Artists"
        case .songs: "Songs"
        }
    }
}

nonisolated struct LocalMusicGroup: Identifiable {
    let id: [String]
    let name: String
    let tracks: [LocalMusicTrack]
    var artworkID: String { tracks.first?.song.coverArtId ?? tracks.first?.id ?? "local:" }

    static func key(for track: LocalMusicTrack, category: LocalMusicCategory) -> [String] {
        category == .albums
            ? [track.song.albumName ?? "", track.song.artist ?? ""]
            : [track.song.artist ?? ""]
    }

    static func groups(in tracks: [LocalMusicTrack], category: LocalMusicCategory) -> [Self] {
        Dictionary(grouping: tracks) { key(for: $0, category: category) }.map { key, tracks in
            Self(id: key, name: key[0].isEmpty
                 ? (category == .albums ? String(localized: "Unknown Album", table: "LocalMusic") : String(localized: "Unknown Artist", table: "LocalMusic"))
                 : key[0], tracks: tracks)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

struct LocalMusicView: View {
    @Environment(\.appContainer) private var container
    @State private var showingSettings = false

    private var tracks: [LocalMusicTrack] {
        (container?.localMusic.snapshot.tracks ?? []).sorted(by: LocalMusicTrack.mostRecentFirst)
    }

    var body: some View {
        Group {
            if container?.localMusic.snapshot.folders.isEmpty != false {
                ContentUnavailableView {
                    Label { Text("Local Files", tableName: "LocalMusic") } icon: { Image(systemName: "folder.fill") }
                } description: {
                    Text("Add music folders from Files. Your audio stays where it is.", tableName: "LocalMusic")
                } actions: {
                    NavigationLink { LocalMusicFoldersView() } label: {
                        Text("Manage Folders", tableName: "LocalMusic")
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if tracks.isEmpty {
                if container?.localMusic.isRefreshing == true {
                    LoadingStateView()
                } else {
                    ContentUnavailableView {
                        Label("No Songs", systemImage: "music.note")
                    } description: {
                        Text("No audio files found. Check your folders in Files, then refresh.", tableName: "LocalMusic")
                    } actions: {
                        Button("Retry") { Task { await container?.localMusic.refresh() } }
                    }
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: MinidiscSpacing.xl) {
                        collectionShelf(.albums)
                        collectionShelf(.artists)
                        VStack(alignment: .leading, spacing: MinidiscSpacing.s) {
                            sectionHeader(.songs)
                            LazyVStack(spacing: 0) {
                                LocalMusicTrackRows(tracks: Array(tracks.prefix(5)), showsDividers: true)
                            }
                            .padding(.horizontal, MinidiscSpacing.l)
                            .minidiscSongSwipeContainer()
                        }
                    }
                    .padding(.top, MinidiscSpacing.m)
                    .padding(.bottom, MinidiscSpacing.xl)
                }
                .miniPlayerBottomMargin()
                .refreshable { await container?.localMusic.refresh() }
            }
        }
        .minidiscContentWidth()
        .navigationTitle(Text("Local Files", tableName: "LocalMusic"))
        .toolbarTitleDisplayMode(.inlineLarge)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink { LocalMusicFoldersView() } label: {
                    Label { Text("Manage Folders", tableName: "LocalMusic") } icon: { Image(systemName: "folder") }
                }
                .tint(.primary)
            }
            if container?.serverState.activeServer == nil {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape.fill") { showingSettings = true }
                }
            }
        }
        .sheet(isPresented: $showingSettings) { SettingsSheet() }
    }

    private func sectionHeader(_ category: LocalMusicCategory) -> some View {
        MinidiscCarouselHeaderLink(category.title, itemCount: tracks.count, hasMore: true) {
            LocalMusicBrowseView(category: category)
        }
    }

    private func collectionShelf(_ category: LocalMusicCategory) -> some View {
        let groups = LocalMusicGroup.groups(in: tracks, category: category).sorted {
            if $0.addedAt != $1.addedAt { return $0.addedAt > $1.addedAt }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return MinidiscShelf {
            sectionHeader(category)
        } content: {
            ForEach(Array(groups.prefix(MinidiscCarouselMetrics.previewLimit))) { group in
                NavigationLink {
                    LocalMusicCollectionView(group: group, category: category)
                } label: {
                    LocalMusicCard(group: group, category: category,
                                   artworkSize: category == .artists ? MinidiscCarouselMetrics.artistArtwork : 160)
                        .frame(width: category == .artists ? MinidiscCarouselMetrics.artistArtwork : 160)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

extension LocalMusicTrack {
    nonisolated var recency: Date { addedAt ?? modified ?? .distantPast }

    nonisolated static func mostRecentFirst(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.recency != rhs.recency { return lhs.recency > rhs.recency }
        let order = lhs.song.title.localizedStandardCompare(rhs.song.title)
        return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
    }
}

extension LocalMusicGroup {
    nonisolated var addedAt: Date { tracks.map(\.recency).max() ?? .distantPast }
    nonisolated var scrollID: String { id.description }
}

struct LocalMusicGrid: View {
    let groups: [LocalMusicGroup]
    let category: LocalMusicCategory
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 240 : 140), spacing: MinidiscSpacing.l)], spacing: MinidiscSpacing.l) {
            ForEach(groups) { group in
                NavigationLink {
                    LocalMusicCollectionView(group: group, category: category)
                } label: {
                    LocalMusicCard(group: group, category: category)
                }
                .buttonStyle(.plain)
                .id(group.scrollID)
            }
        }
    }
}

struct LocalMusicCard: View {
    let group: LocalMusicGroup
    let category: LocalMusicCategory
    var artworkSize: CGFloat? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: MinidiscSpacing.s) {
            LocalMusicArtwork(id: group.artworkID, isArtist: category == .artists)
                .aspectRatio(1, contentMode: .fit)
                .frame(width: artworkSize, height: artworkSize)
            if category == .artists {
                Text(group.name)
                    .font(.minidiscCellTitle)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            } else {
                CoverCardMetadata(title: group.name, subtitle: group.tracks.first?.song.artist)
            }
        }
        .foregroundStyle(.primary)
    }
}

struct LocalMusicArtwork: View {
    let id: String
    var isArtist = false

    var body: some View {
        GeometryReader { geometry in
            CoverArtView(id: id, size: Int(geometry.size.width * 2), cornerRadius: 0)
                .frame(width: geometry.size.width, height: geometry.size.width)
                .clipShape(RoundedRectangle(cornerRadius: isArtist ? geometry.size.width / 2 : MinidiscCornerRadius.standard))
        }
        .accessibilityHidden(true)
    }
}
