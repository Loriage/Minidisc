// Minidisc — Music client for Subsonic/OpenSubsonic servers
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// A Lidarr artist: header, overview, and the albums Lidarr tracks. Albums can be monitored, and the
/// "…" menu refreshes, searches, opens MusicBrainz, or removes the artist.
struct LidarrArtistDetailView: View {
    let artist: LidarrArtist
    let client: LidarrClient

    @Environment(\.appContainer) private var container
    @Environment(\.dismiss) private var dismiss

    @State private var albums: [LidarrAlbum] = []
    @State private var isLoading = true
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var showDeleteAlert = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MinidiscSpacing.l) {
                header
                searchButton
                albumsSection
            }
            .padding(MinidiscSpacing.l)
        }
        .navigationTitle(artist.artistName)
        .navigationBarTitleDisplayModeInline()
        .navigationDestination(for: LidarrAlbum.self) { album in
            LidarrAlbumDetailView(album: album, client: client)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { optionsMenu }
        }
        .alert("Remove \(artist.artistName)?", isPresented: $showDeleteAlert) {
            Button("Remove", role: .destructive) { Task { await delete() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Lidarr stops managing this artist. The downloaded files are kept.")
        }
        .task { await loadAlbums() }
    }

    // MARK: - Menu

    private var optionsMenu: some View {
        Menu {
            Button {
                Task { await refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            Button {
                Task { await triggerSearch() }
            } label: {
                Label("Search Monitored", systemImage: "magnifyingglass")
            }
            .disabled(!artist.monitored)

            if let url = artist.musicBrainzURL {
                Divider()
                Link(destination: url) {
                    Label("Open in MusicBrainz", systemImage: "arrow.up.right.square")
                }
            }

            Divider()
            Button(role: .destructive) {
                showDeleteAlert = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .tint(.primary)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: MinidiscSpacing.m) {
            LidarrCoverImage(path: artist.posterPath, client: client) {
                RoundedRectangle(cornerRadius: MinidiscCornerRadius.standard)
                    .fill(Color.secondary.opacity(0.15))
                    .overlay { Image(systemName: "music.mic").font(.title).foregroundStyle(.secondary) }
            }
            .frame(width: 120, height: 120)
            .clipShape(RoundedRectangle(cornerRadius: MinidiscCornerRadius.standard))

            VStack(alignment: .leading, spacing: MinidiscSpacing.xs) {
                Text(artist.artistName).font(.minidiscDetailTitle).lineLimit(3)
                Label(artist.monitored ? "Monitored" : "Not monitored",
                      systemImage: artist.monitored ? "bookmark.fill" : "bookmark")
                    .font(.minidiscCaption)
                    .foregroundStyle(.secondary)
                if let count = artist.statistics?.albumCount {
                    Text(count == 1 ? "1 album" : "\(count) albums")
                        .font(.minidiscCaption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var searchButton: some View {
        HStack(spacing: MinidiscSpacing.m) {
            Button {
                Task { await triggerSearch() }
            } label: {
                HStack {
                    if isSearching {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "magnifyingglass")
                    }
                    Text("Search Monitored")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, MinidiscSpacing.s)
            }
            .disabled(isSearching || !artist.monitored)

            NavigationLink(value: LidarrInteractiveSearchRoute(scope: .artist(artist))) {
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

    /// Albums grouped by type in Lidarr's order (Album, EP, Single, then anything else).
    private var albumGroups: [(title: String, albums: [LidarrAlbum])] {
        let order = ["Album", "EP", "Single", "Broadcast", "Other"]
        let titles = ["Album": "Albums", "EP": "EPs", "Single": "Singles", "Broadcast": "Broadcasts", "Other": "Other"]
        let grouped = Dictionary(grouping: albums) { $0.albumType ?? "Album" }
        var result: [(String, [LidarrAlbum])] = []
        for type in order where !(grouped[type] ?? []).isEmpty {
            result.append((titles[type] ?? type, grouped[type]!))
        }
        for (type, items) in grouped where !order.contains(type) {
            result.append((type, items))
        }
        return result
    }

    @ViewBuilder
    private var albumsSection: some View {
        if let overview = artist.overview, !overview.isEmpty {
            Text(overview)
                .font(.minidiscBody)
                .foregroundStyle(.secondary)
        }

        if isLoading {
            Text("Albums").font(.minidiscShelfTitle)
            ProgressView().frame(maxWidth: .infinity)
        } else if let errorMessage {
            Text("Albums").font(.minidiscShelfTitle)
            Text(errorMessage).font(.minidiscCaption).foregroundStyle(.orange)
        } else if albums.isEmpty {
            Text("Albums").font(.minidiscShelfTitle)
            Text("No albums.").font(.minidiscCaption).foregroundStyle(.secondary)
        } else {
            ForEach(albumGroups, id: \.title) { group in
                VStack(alignment: .leading, spacing: MinidiscSpacing.s) {
                    Text(group.title)
                        .font(.minidiscShelfTitle)
                    VStack(spacing: 0) {
                        ForEach(group.albums) { album in
                            LidarrAlbumRow(
                                album: album,
                                client: client,
                                onToggleMonitor: { newValue in setMonitored(albumId: album.id, to: newValue) }
                            )
                            if album.id != group.albums.last?.id { Divider() }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func loadAlbums() async {
        errorMessage = nil
        do {
            let fetched = try await client.albums(artistId: artist.id)
            albums = fetched.sorted { ($0.year ?? "") > ($1.year ?? "") }
        } catch {
            if let lidarr = error as? LidarrError, case .cancelled = lidarr {} else {
                errorMessage = LidarrLibraryView.message(for: (error as? LidarrError) ?? .transport(error.localizedDescription))
            }
        }
        isLoading = false
    }

    /// Optimistically flips the album's local monitored flag, then persists it, reverting on failure.
    private func setMonitored(albumId: Int, to newValue: Bool) {
        guard let index = albums.firstIndex(where: { $0.id == albumId }) else { return }
        let previous = albums[index].monitored
        albums[index].monitored = newValue
        Task {
            do {
                try await client.setAlbumsMonitored(albumIds: [albumId], monitored: newValue)
            } catch {
                albums[index].monitored = previous
                container?.toastService.showError(String(localized: "Couldn't update monitoring."))
            }
        }
    }

    private func triggerSearch() async {
        isSearching = true
        defer { isSearching = false }
        do {
            try await client.triggerArtistSearch(artistId: artist.id)
            container?.toastService.showSuccess(String(localized: "Search started in Lidarr"))
        } catch {
            container?.toastService.showError(String(localized: "Couldn't start the search."))
        }
    }

    private func refresh() async {
        do {
            try await client.refreshArtist(artistId: artist.id)
            container?.toastService.showSuccess(String(localized: "Refresh started in Lidarr"))
        } catch {
            container?.toastService.showError(String(localized: "Couldn't refresh."))
        }
    }

    private func delete() async {
        do {
            try await client.deleteArtist(artistId: artist.id, deleteFiles: false)
            NotificationCenter.default.post(name: .lidarrLibraryDidChange, object: nil)
            container?.toastService.showConfirmation(String(localized: "Removed from Lidarr"))
            dismiss()
        } catch {
            container?.toastService.showError(String(localized: "Couldn't remove the artist."))
        }
    }
}

// MARK: - Album row

private struct LidarrAlbumRow: View {
    let album: LidarrAlbum
    let client: LidarrClient
    let onToggleMonitor: (Bool) -> Void

    var body: some View {
        HStack(spacing: MinidiscSpacing.m) {
            NavigationLink(value: album) {
                HStack(spacing: MinidiscSpacing.m) {
                    LidarrCoverImage(path: album.coverPath, client: client) {
                        RoundedRectangle(cornerRadius: MinidiscCornerRadius.standard)
                            .fill(Color.secondary.opacity(0.15))
                            .overlay { Image(systemName: "opticaldisc").foregroundStyle(.secondary) }
                    }
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: MinidiscCornerRadius.standard))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(album.title).font(.minidiscCellTitle).lineLimit(1)
                        HStack(spacing: MinidiscSpacing.xs) {
                            if let year = album.year { Text(year) }
                            if let progress = album.trackProgress {
                                Text("·")
                                Text("\(progress) tracks")
                            }
                        }
                        .font(.minidiscCaption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                HapticFeedback.light.trigger()
                onToggleMonitor(!album.monitored)
            } label: {
                Image(systemName: album.monitored ? "bookmark.fill" : "bookmark")
                    .font(.title3)
                    .foregroundStyle(album.monitored ? Color.minidiscAccent : .secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(album.monitored ? "Stop monitoring" : "Monitor")
        }
        .padding(.vertical, MinidiscSpacing.s)
    }
}
