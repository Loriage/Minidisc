import SwiftUI

/// A Lidarr album: header, a per-medium track list, monitoring, and an album search.
struct LidarrAlbumDetailView: View {
    let album: LidarrAlbum
    let client: LidarrClient

    @Environment(\.appContainer) private var container

    @State private var tracks: [LidarrTrack] = []
    @State private var monitored: Bool
    @State private var isLoading = true
    @State private var isSearching = false
    @State private var errorMessage: String?

    init(album: LidarrAlbum, client: LidarrClient) {
        self.album = album
        self.client = client
        _monitored = State(initialValue: album.monitored)
    }

    /// Track numbers present, grouped by medium in order.
    private var mediumNumbers: [Int] {
        let numbers = Set(tracks.map { $0.mediumNumber ?? 1 })
        return numbers.sorted()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MinidiscSpacing.l) {
                header
                searchButton
                tracksSection
            }
            .padding(MinidiscSpacing.l)
        }
        .navigationTitle(album.title)
        .navigationBarTitleDisplayModeInline()
        .task { await loadTracks() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: MinidiscSpacing.m) {
            LidarrCoverImage(path: album.coverPath, client: client) {
                RoundedRectangle(cornerRadius: MinidiscCornerRadius.standard)
                    .fill(Color.secondary.opacity(0.15))
                    .overlay { Image(systemName: "opticaldisc").font(.title).foregroundStyle(.secondary) }
            }
            .frame(width: 120, height: 120)
            .clipShape(RoundedRectangle(cornerRadius: MinidiscCornerRadius.standard))

            VStack(alignment: .leading, spacing: MinidiscSpacing.xs) {
                Text(album.title).font(.minidiscDetailTitle).lineLimit(3)
                if let year = album.year {
                    Text(year).font(.minidiscCaption).foregroundStyle(.secondary)
                }
                if let progress = album.trackProgress {
                    Text("\(progress) tracks").font(.minidiscCaption).foregroundStyle(.secondary)
                }
                Button {
                    HapticFeedback.light.trigger()
                    toggleMonitor()
                } label: {
                    Label(monitored ? "Monitored" : "Not monitored",
                          systemImage: monitored ? "bookmark.fill" : "bookmark")
                        .font(.minidiscCaption)
                        .foregroundStyle(monitored ? Color.minidiscAccent : .secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    private var searchButton: some View {
        HStack(spacing: MinidiscSpacing.m) {
            Button {
                Task { await searchAlbum() }
            } label: {
                HStack {
                    if isSearching {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "magnifyingglass")
                    }
                    Text("Search Album")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, MinidiscSpacing.s)
            }
            .disabled(isSearching)

            NavigationLink(value: LidarrInteractiveSearchRoute(scope: .album(album))) {
                HStack {
                    Image(systemName: "person.fill.viewfinder")
                    Text("Interactive")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, MinidiscSpacing.s)
            }
        }
        .buttonStyle(.bordered)
        .tint(.minidiscAccent)
    }

    @ViewBuilder
    private var tracksSection: some View {
        if isLoading {
            ProgressView().frame(maxWidth: .infinity)
        } else if let errorMessage {
            Text(errorMessage).font(.minidiscCaption).foregroundStyle(.orange)
        } else if tracks.isEmpty {
            Text("No tracks.").font(.minidiscCaption).foregroundStyle(.secondary)
        } else {
            ForEach(mediumNumbers, id: \.self) { medium in
                let mediumTracks = tracks.filter { ($0.mediumNumber ?? 1) == medium }
                VStack(alignment: .leading, spacing: MinidiscSpacing.s) {
                    if mediumNumbers.count > 1 || (album.media?.count ?? 0) > 1 {
                        Text(album.mediumTitle(for: medium))
                            .font(.minidiscShelfTitle)
                    } else {
                        Text("Tracks")
                            .font(.minidiscShelfTitle)
                    }
                    VStack(spacing: 0) {
                        ForEach(mediumTracks) { track in
                            LidarrTrackRow(track: track)
                            if track.id != mediumTracks.last?.id { Divider() }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func loadTracks() async {
        errorMessage = nil
        do {
            let fetched = try await client.tracks(albumId: album.id)
            tracks = fetched.sorted {
                ($0.mediumNumber ?? 1, Int($0.trackNumber ?? "") ?? 0) < ($1.mediumNumber ?? 1, Int($1.trackNumber ?? "") ?? 0)
            }
        } catch {
            if let lidarr = error as? LidarrError, case .cancelled = lidarr {} else {
                errorMessage = LidarrLibraryView.message(for: (error as? LidarrError) ?? .transport(error.localizedDescription))
            }
        }
        isLoading = false
    }

    private func toggleMonitor() {
        let newValue = !monitored
        monitored = newValue
        Task {
            do {
                try await client.setAlbumsMonitored(albumIds: [album.id], monitored: newValue)
            } catch {
                monitored = !newValue
                container?.toastService.showError(String(localized: "Couldn't update monitoring."))
            }
        }
    }

    private func searchAlbum() async {
        isSearching = true
        defer { isSearching = false }
        do {
            try await client.triggerAlbumSearch(albumIds: [album.id])
            container?.toastService.showSuccess(String(localized: "Search started in Lidarr"))
        } catch {
            container?.toastService.showError(String(localized: "Couldn't start the search."))
        }
    }
}

// MARK: - Track row

private struct LidarrTrackRow: View {
    let track: LidarrTrack

    var body: some View {
        HStack(spacing: MinidiscSpacing.m) {
            Text(track.trackNumber ?? "–")
                .font(.minidiscCaption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).font(.minidiscCellTitle).lineLimit(1)
                HStack(spacing: MinidiscSpacing.xs) {
                    Text(track.hasFile ? "Downloaded" : "Missing")
                    if let duration = track.durationText {
                        Text("·")
                        Text(duration)
                    }
                }
                .font(.minidiscCaption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)

            Image(systemName: track.hasFile ? "checkmark.circle.fill" : "circle.dashed")
                .font(.body)
                .foregroundStyle(track.hasFile ? Color(.systemGreen) : .secondary)
        }
        .padding(.vertical, MinidiscSpacing.s)
    }
}
