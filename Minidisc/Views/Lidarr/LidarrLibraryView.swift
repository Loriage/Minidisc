import SwiftUI

struct LidarrLibraryView: View {
    @Environment(\.appContainer) private var container

    @State private var artists: [LidarrArtist] = []
    @State private var isLoading = true
    @State private var failedOffline = false
    @State private var loadGeneration = 0
    @State private var errorMessage: String?
    @State private var client: LidarrClient?
    @State private var showSearch = false
    // Keep Lidarr’s sort preference separate from the music-server library.
    @AppStorage("minidisc.lidarrArtistSort") private var artistSort: ArtistSort = .name
    @AppStorage("minidisc.lidarrLibraryGrid") private var gridLayout = true

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 180), spacing: MinidiscSpacing.m)]

    private var isOffline: Bool { container?.serverState.isOnline == false || failedOffline }

    private var sortedArtists: [LidarrArtist] { artistSort.sortedLidarr(artists) }

    var body: some View {
        Group {
            if isOffline && artists.isEmpty {
                ContentUnavailableView {
                    Label("You're Offline", systemImage: "wifi.slash")
                } description: {
                    Text("Reconnect to browse Lidarr and manage your music library. Your offline music is still available in Minidisc.")
                } actions: {
                    Button("Retry") { Task { await load() } }
                        .buttonStyle(.bordered)
                        .disabled(container?.serverState.isOnline == false)
                }
                .accessibilityIdentifier("lidarr-offline")
            } else if isLoading && artists.isEmpty {
                LoadingStateView()
            } else if let errorMessage, artists.isEmpty {
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
                    .disabled(isOffline)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        if isOffline {
                            Label("Offline — showing previously loaded artists.", systemImage: "wifi.slash")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .padding()
                                .frame(maxWidth: .infinity)
                                .background(.bar)
                        } else if let errorMessage {
                            Text(errorMessage).font(.subheadline).foregroundStyle(.secondary).padding()
                        }
                    }
            }
        }
        .navigationTitle("Lidarr")
        .toolbar {
            if !artists.isEmpty {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button(
                        gridLayout ? "List view" : "Grid view",
                        systemImage: gridLayout ? "list.bullet" : "square.grid.2x2"
                    ) { gridLayout.toggle() }
                    .tint(.primary)
                    Menu {
                        Picker("Sort By", selection: $artistSort) {
                            ForEach(ArtistSort.allCases, id: \.self) { option in
                                Label(option.label, systemImage: option.systemImage).tag(option)
                            }
                        }
                    } label: {
                        Label("Sort", systemImage: "arrow.up.arrow.down")
                    }
                    .tint(.primary)
                }
            }
            if !isOffline {
                ToolbarItemGroup(placement: .primaryAction) {
                    NavigationLink(value: LidarrQueueRoute()) {
                        Label("Activity", systemImage: "waveform.path.ecg")
                    }
                    .tint(.primary)
                    Button("Add Artist", systemImage: "plus") { showSearch = true }
                        .tint(.primary)
                }
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
        .task(id: container?.serverState.isOnline) { await load() }
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
        loadGeneration += 1
        let generation = loadGeneration
        failedOffline = false
        errorMessage = nil
        guard container?.serverState.isOnline != false else {
            isLoading = false
            return
        }
        isLoading = artists.isEmpty
        defer { if loadGeneration == generation { isLoading = false } }
        if client == nil { client = await container?.lidarrSettings.makeClient() }
        guard let client else {
            isLoading = false
            errorMessage = String(localized: "Lidarr is not connected.")
            return
        }
        guard !Task.isCancelled, generation == loadGeneration else { return }
        errorMessage = nil
        do {
            let fetched = try await client.artists()
            guard !Task.isCancelled, generation == loadGeneration else { return }
            artists = fetched.sorted { $0.artistName.localizedCaseInsensitiveCompare($1.artistName) == .orderedAscending }
        } catch {
            guard !Task.isCancelled, generation == loadGeneration else { return }
            if let lidarr = error as? LidarrError, lidarr == .cancelled { return }
            failedOffline = (error as? LidarrError) == .offline || UserFacingError.from(error) == .noNetwork
            errorMessage = (error as? LidarrError).map(Self.message(for:)) ?? UserFacingError.from(error).displayMessage
        }
        isLoading = false
    }

    static func message(for error: LidarrError) -> String {
        switch error {
        case .unauthorized: return String(localized: "The API key was rejected.")
        case .htmlResponse: return String(localized: "A reverse proxy is blocking the request.")
        case .cancelled: return ""
        case .badURL: return String(localized: "The Lidarr address is not valid.")
        case .offline: return UserFacingError.noNetwork.displayMessage
        case .transport: return UserFacingError.serverUnreachable.displayMessage
        case .decoding: return String(localized: "Lidarr returned an unreadable response. Try again later.")
        }
    }
}

// MARK: - Artist cell

private struct LidarrArtistCell: View {
    let artist: LidarrArtist
    let client: LidarrClient

    var body: some View {
        VStack(alignment: .leading, spacing: MinidiscSpacing.xs) {
            // Size the cell before overlaying artwork so wide banners cannot expand the grid column.
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

            CoverCardMetadata(
                title: artist.artistName,
                subtitle: artist.statistics?.albumCount == 1
                    ? String(localized: "1 album")
                    : String(localized: "\(artist.statistics?.albumCount ?? 0) albums")
            )
        }
    }
}

// MARK: - Artist row

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
                if a != b { return a > b }
                return $0.artistName.localizedStandardCompare($1.artistName) == .orderedAscending
            }
        }
    }
}
