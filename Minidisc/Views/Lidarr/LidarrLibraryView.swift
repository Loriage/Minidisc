import SwiftUI

/// The Lidarr tab: a grid of the artists Lidarr manages, with a button to search and add more.
struct LidarrLibraryView: View {
    @Environment(\.appContainer) private var container

    @State private var artists: [LidarrArtist] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var client: LidarrClient?
    @State private var showSearch = false
    // Keyed separately from `minidisc.artistSort`: this is a different library, and re-sorting the
    // Subsonic artists list from the Lidarr tab would be a surprise.
    @AppStorage("minidisc.lidarrArtistSort") private var artistSort: ArtistSort = .name
    @AppStorage("minidisc.lidarrLibraryGrid") private var gridLayout = true

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 180), spacing: MinidiscSpacing.m)]

    /// Server order is alphabetical; this applies the user's choice on top.
    private var sortedArtists: [LidarrArtist] { artistSort.sortedLidarr(artists) }

    var body: some View {
        Group {
            if isLoading {
                LoadingStateView()
            } else if let errorMessage {
                EmptyStateView(
                    systemImage: "exclamationmark.triangle",
                    title: "Couldn't Load Lidarr",
                    subtitle: LocalizedStringKey(errorMessage),
                    action: .init(label: "Retry") { Task { await load() } }
                )
            } else if artists.isEmpty {
                EmptyStateView(
                    systemImage: "music.mic",
                    title: "No Artists Yet",
                    subtitle: "Tap + to search Lidarr and add an artist."
                )
            } else {
                grid
            }
        }
        .navigationTitle("Lidarr")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink(value: LidarrQueueRoute()) {
                    Image(systemName: "waveform.path.ecg")
                }
                .tint(.primary)
                .accessibilityLabel("Activity")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Sort By", selection: $artistSort) {
                        ForEach(ArtistSort.allCases, id: \.self) { option in
                            Label(option.label, systemImage: option.systemImage).tag(option)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .tint(.primary)
                .accessibilityLabel("Sort")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { gridLayout.toggle() } label: {
                    Image(systemName: gridLayout ? "list.bullet" : "square.grid.2x2")
                }
                .tint(.primary)
                .accessibilityLabel(gridLayout ? "List view" : "Grid view")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showSearch = true } label: {
                    Image(systemName: "plus")
                }
                .tint(.primary)
                .accessibilityLabel("Add Artist")
            }
        }
        .sheet(isPresented: $showSearch, onDismiss: { Task { await load() } }) {
            LidarrArtistSearchView()
        }
        .navigationDestination(for: LidarrArtist.self) { artist in
            if let client {
                LidarrArtistDetailView(artist: artist, client: client)
            }
        }
        .navigationDestination(for: LidarrInteractiveSearchRoute.self) { route in
            if let client {
                LidarrInteractiveSearchView(scope: route.scope, client: client)
            }
        }
        .navigationDestination(for: LidarrQueueRoute.self) { _ in
            if let client {
                LidarrQueueView(client: client)
            }
        }
        .task {
            if client == nil { client = await container?.lidarrSettings.makeClient() }
            await load()
        }
        .refreshable { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .lidarrLibraryDidChange)) { _ in
            Task { await load() }
        }
    }

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if gridLayout {
                    LazyVGrid(columns: columns, spacing: MinidiscSpacing.l) {
                        ForEach(sortedArtists) { artist in
                            NavigationLink(value: artist) {
                                if let client {
                                    LidarrArtistCell(artist: artist, client: client)
                                }
                            }
                            .buttonStyle(.plain)
                            .id(artist.id)
                        }
                    }
                    .padding(MinidiscSpacing.l)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(sortedArtists) { artist in
                            NavigationLink(value: artist) {
                                if let client {
                                    LidarrArtistRow(artist: artist, client: client)
                                }
                            }
                            .buttonStyle(.plain)
                            .id(artist.id)
                        }
                    }
                    .padding(.horizontal, MinidiscSpacing.l)
                    .padding(.vertical, MinidiscSpacing.s)
                }
            }
            .safeAreaInset(edge: .trailing, spacing: 0) {
                // Only meaningful while the order is alphabetical — under Album Count the letters
                // are scattered through the list and jumping to one lands somewhere arbitrary.
                let letters = artistSort == .name
                    ? artists.availableAlphabetLetters(keyPath: \.artistName)
                    : []
                if letters.count >= 5 {
                    AlphabetJumpBar(
                        availableLetters: letters,
                        onLetterTap: { letter in
                            if let id = firstAlphabetItemID(forLetter: letter, in: sortedArtists, keyPath: \.artistName) {
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

    private func load() async {
        if client == nil { client = await container?.lidarrSettings.makeClient() }
        guard let client else {
            isLoading = false
            errorMessage = String(localized: "Lidarr is not connected.")
            return
        }
        errorMessage = nil
        do {
            let fetched = try await client.artists()
            artists = fetched.sorted { $0.artistName.localizedCaseInsensitiveCompare($1.artistName) == .orderedAscending }
        } catch {
            if let lidarr = error as? LidarrError, case .cancelled = lidarr {} else {
                errorMessage = (error as? LidarrError).map(Self.message(for:)) ?? error.localizedDescription
            }
        }
        isLoading = false
    }

    static func message(for error: LidarrError) -> String {
        switch error {
        case .unauthorized: return String(localized: "The API key was rejected.")
        case .htmlResponse: return String(localized: "A reverse proxy is blocking the request.")
        case .cancelled: return ""
        case .badURL: return String(localized: "The Lidarr address is not valid.")
        case .transport(let d), .decoding(let d): return d
        }
    }
}

// MARK: - Artist cell

private struct LidarrArtistCell: View {
    let artist: LidarrArtist
    let client: LidarrClient

    var body: some View {
        VStack(alignment: .leading, spacing: MinidiscSpacing.xs) {
            // The square is driven by an inert Color, and the cover rides in an overlay: overlay
            // content never contributes to its parent's size. Lidarr falls back to a banner when an
            // artist has no poster, and `scaledToFill` reports a size WIDER than proposed for such a
            // cover — through a flexible maxWidth frame that width reached the grid, which then
            // centred the oversized cell over its neighbour. Here it can only overflow the clip.
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    LidarrCoverImage(path: artist.posterPath, client: client) {
                        RoundedRectangle(cornerRadius: MinidiscCornerRadius.standard)
                            .fill(Color.secondary.opacity(0.15))
                            .overlay { Image(systemName: "music.mic").font(.title).foregroundStyle(.secondary) }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: MinidiscCornerRadius.standard))
            .overlay(alignment: .topTrailing) {
                if !artist.monitored {
                    Image(systemName: "bookmark.slash.fill")
                        .font(.caption)
                        .foregroundStyle(.white, .black.opacity(0.4))
                        .padding(MinidiscSpacing.xs)
                }
            }

            Text(artist.artistName)
                .font(.minidiscCaption)
                .fontWeight(.semibold)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(artist.statistics?.albumCount == 1 ? "1 album" : "\(artist.statistics?.albumCount ?? 0) albums")
                .font(.minidiscCaption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

// MARK: - Artist row

/// List-mode counterpart of `LidarrArtistCell`, laid out like `ArtistRow` on the Subsonic side.
private struct LidarrArtistRow: View {
    let artist: LidarrArtist
    let client: LidarrClient

    var body: some View {
        HStack(spacing: MinidiscSpacing.m) {
            Color.clear
                .frame(width: 44, height: 44)
                .overlay {
                    LidarrCoverImage(path: artist.posterPath, client: client) {
                        RoundedRectangle(cornerRadius: MinidiscCornerRadius.s)
                            .fill(Color.secondary.opacity(0.15))
                            .overlay { Image(systemName: "music.mic").foregroundStyle(.secondary) }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: MinidiscCornerRadius.s))

            VStack(alignment: .leading, spacing: 2) {
                Text(artist.artistName)
                    .font(.minidiscCellTitle)
                    .lineLimit(1)
                Text(artist.statistics?.albumCount == 1 ? "1 album" : "\(artist.statistics?.albumCount ?? 0) albums")
                    .font(.minidiscCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if !artist.monitored {
                Image(systemName: "bookmark.slash.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, MinidiscSpacing.s)
        .contentShape(Rectangle())
    }
}

// MARK: - Sorting

private extension ArtistSort {
    /// `ArtistSort.sorted` is typed to SwiftSonic's `ArtistID3`; Lidarr has its own model, so the same
    /// two orderings are applied here rather than coupling the domain enum to the Lidarr layer.
    func sortedLidarr(_ artists: [LidarrArtist]) -> [LidarrArtist] {
        switch self {
        case .name:
            return artists.sorted { $0.artistName.localizedStandardCompare($1.artistName) == .orderedAscending }
        case .albumCount:
            return artists.sorted {
                let a = $0.statistics?.albumCount ?? 0, b = $1.statistics?.albumCount ?? 0
                if a != b { return a > b } // most albums first
                return $0.artistName.localizedStandardCompare($1.artistName) == .orderedAscending
            }
        }
    }
}
