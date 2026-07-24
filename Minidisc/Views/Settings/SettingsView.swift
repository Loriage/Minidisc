// Minidisc — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import OSLog
import SwiftUI

/// Beszel-style settings presentation: a sheet with its own NavigationStack,
/// inline title, and an X close button.
struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SettingsView()
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.body.weight(.semibold))
                        }
                        .tint(.primary)
                    }
                }
        }
    }
}

struct SettingsView: View {
    @Environment(\.appContainer) private var container
    @State private var downloadsVM: DownloadsViewModel?

    var body: some View {
        Group {
            if let downloadsVM {
                form(downloadsVM: downloadsVM)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .minidiscContentWidth()
        .navigationTitle("Settings")
        .task {
            guard let container else { return }
            if downloadsVM == nil {
                downloadsVM = DownloadsViewModel(
                    modelContainer: container.modelContainer,
                    downloadService: container.downloadService,
                    serverState: container.serverState
                )
            }
            await downloadsVM?.loadData()
        }
    }

    private func form(downloadsVM: DownloadsViewModel) -> some View {
        Form {
            serverSection()
            // Apple Music-style hub: one untitled group, each row pushes a focused sub-page.
            Section {
                NavigationLink {
                    PlaybackSettingsView()
                } label: {
                    Label("Playback", systemImage: "play.circle")
                        .foregroundStyle(.primary)
                }
                NavigationLink {
                    StorageSettingsView(vm: downloadsVM)
                } label: {
                    Label("Storage", systemImage: "internaldrive")
                        .foregroundStyle(.primary)
                }
                NavigationLink {
                    IntegrationsSettingsView()
                } label: {
                    Label("Integrations", systemImage: "puzzlepiece.extension")
                        .foregroundStyle(.primary)
                }
            }
            aboutSection()
            ApplicationSectionView(vm: downloadsVM)
        }
        .formStyle(.grouped)
        .refreshable {
            await downloadsVM.loadData()
        }
    }

    // MARK: - Sections

    private func serverSection() -> some View {
        Section {
            if let server = container?.serverState.activeServer,
               let serverService = container?.serverService {
                NavigationLink {
                    EditServerDestinationView(server: server, serverService: serverService)
                } label: {
                    HStack {
                        Text(server.displayName)
                        Spacer()
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
            } else {
                Text("No server configured.")
                    .foregroundStyle(.secondary)
            }
            // TODO(v1.x): multi-server management (add / remove / switch servers)
        } header: {
            Text("Server")
        } footer: {
            if let server = container?.serverState.activeServer {
                Text(server.baseURL)
            }
        }
    }

    fileprivate static var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }

    private func aboutSection() -> some View {
        Section {
            ShareLink(item: MinidiscURLs.repo) {
                Label("Share the App", systemImage: "square.and.arrow.up")
            }
            .foregroundStyle(.primary)
            Link(destination: MinidiscURLs.repoIssues) {
                Label("Report an Issue", systemImage: "exclamationmark.bubble")
            }
            .foregroundStyle(.primary)
            Button {
                ExternalLinkOpener.open(MinidiscURLs.repo)
            } label: {
                Label("View on GitHub", systemImage: "link")
            }
            .foregroundStyle(.primary)
            NavigationLink {
                AcknowledgementsView()
            } label: {
                Label("Acknowledgements", systemImage: "text.badge.star")
                    .foregroundStyle(.primary)
            }
        } header: {
            Text("About")
        }
    }
}

// MARK: - Storage sub-page

struct StorageSettingsView: View {
    let vm: DownloadsViewModel
    @Environment(\.appContainer) private var container
    @Environment(ArtworkImageCache.self) private var artworkImageCache
    @State private var usedBytes: Int64 = 0
    @State private var trackCount: Int = 0
    @State private var coverCount: Int = 0
    @State private var coverBytes: Int64 = 0
    @State private var isClearingCache = false
    @State private var showClearCacheConfirm = false
    @State private var showClearArtworkConfirm = false

    private var cacheSettings: CacheSettings? { container?.cacheSettings }

    var body: some View {
        let maxTracks = cacheSettings?.maxTracks ?? 10

        return Form {
            Section {
            LabeledContent {
                Text(vm.trackCount == 1 ? "1 track · \(vm.usedBytesFormatted)" : "\(vm.trackCount) tracks · \(vm.usedBytesFormatted)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } label: {
                Text("Offline downloads")
                    .foregroundStyle(.primary)
            }

            if !vm.displayAlbums.isEmpty {
                DisclosureGroup {
                    ForEach(vm.displayAlbums) { album in
                        HStack(spacing: MinidiscSpacing.m) {
                            CoverArtCard(id: album.coverArtId ?? album.albumId, size: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(album.name)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                if let total = album.totalTracksCount {
                                    Text("\(album.downloadedTracksCount)/\(total) tracks")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("\(album.downloadedTracksCount) tracks")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button(role: .destructive) {
                                Task { await vm.removeAlbum(album) }
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                } label: {
                    Text("Albums (\(vm.displayAlbums.count))")
                        .foregroundStyle(.primary)
                }
            }

            if !vm.downloadedPlaylists.isEmpty {
                DisclosureGroup {
                    ForEach(vm.downloadedPlaylists) { playlist in
                        HStack(spacing: MinidiscSpacing.m) {
                            CoverArtCard(id: playlist.playlistId, size: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(playlist.name)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                Text("\(playlist.tracksCount)/\(playlist.totalTracksCount) tracks")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                Task { await vm.removePlaylist(playlist) }
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                } label: {
                    Text("Playlists (\(vm.downloadedPlaylists.count))")
                        .foregroundStyle(.primary)
                }
            }
            } header: {
                Text("Downloads")
            } footer: {
                Text("Downloaded tracks are stored permanently and available offline.")
            }

            Section {
                LabeledContent {
                    Text("\(ByteCountFormatter.string(fromByteCount: usedBytes, countStyle: .file)) · \(trackCount)/\(maxTracks) tracks")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } label: {
                    Text("Used")
                        .foregroundStyle(.primary)
                }

                if let cacheSettings {
                    Stepper(
                        value: Binding(
                            get: { cacheSettings.maxTracks },
                            set: { cacheSettings.maxTracks = max(1, min(10, $0)) }
                        ),
                        in: 1...10
                    ) {
                        HStack {
                            Text("Max tracks")
                                .foregroundStyle(.primary)
                            Spacer()
                            Text("\(maxTracks)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .font(.body.weight(.medium))
                        }
                    }

                    Picker(selection: Binding<CacheFormat>(
                        get: { cacheSettings.cacheFormat },
                        set: { newValue in cacheSettings.cacheFormat = newValue }
                    )) {
                        ForEach(CacheFormat.allCases) { format in
                            Text(format.displayName).tag(format)
                        }
                    } label: {
                        Text("Format")
                            .foregroundStyle(.primary)
                    }
                    .pickerStyle(.menu)
                    .tint(.secondary)

                    Toggle(isOn: Binding(
                        get: { cacheSettings.cacheOverCellular },
                        set: { cacheSettings.cacheOverCellular = $0 }
                    )) {
                        Text("Use cellular data")
                            .foregroundStyle(.primary)
                    }
                    .tint(Color(.systemGreen))
                }

                Button(role: .destructive) {
                    showClearCacheConfirm = true
                } label: {
                    if isClearingCache {
                        HStack(spacing: MinidiscSpacing.s) {
                            ProgressView().scaleEffect(0.8)
                            Text("Clearing…")
                        }
                    } else {
                        Text("Clear stream cache")
                            .foregroundStyle(.red)
                    }
                }
                .disabled(isClearingCache)
            } header: {
                Text("Stream cache")
            } footer: {
                Text("Keeps recently-played music for instant replay — the oldest track is replaced when the limit is reached.")
            }

            Section {
                LabeledContent {
                    Text(coverCount == 1 ? "1 image · \(ByteCountFormatter.string(fromByteCount: coverBytes, countStyle: .file))" : "\(coverCount) images · \(ByteCountFormatter.string(fromByteCount: coverBytes, countStyle: .file))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } label: {
                    Text("Disk usage")
                        .foregroundStyle(.primary)
                }

                if let cacheSettings {
                    Toggle(isOn: Binding(
                        get: { cacheSettings.cacheArtwork },
                        set: { newValue in
                            cacheSettings.cacheArtwork = newValue
                            artworkImageCache.persistCoversEnabled = newValue
                        }
                    )) {
                        Text("Cache artwork")
                            .foregroundStyle(.primary)
                    }
                    .tint(Color(.systemGreen))
                }

                Button(role: .destructive) {
                    showClearArtworkConfirm = true
                } label: {
                    Text("Clear artwork cache")
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Artwork")
            } footer: {
                Text("Covers re-download on demand. Turning caching off keeps artwork in memory only.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Storage")
        .navigationBarTitleDisplayModeInline()
        .background {
            Color.clear
                .alert("Clear stream cache?", isPresented: $showClearCacheConfirm) {
                    Button("Clear", role: .destructive) { Task { await clearStreamCache() } }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Recently-played music is removed from the cache. It re-downloads on demand.")
                }
                .alert("Clear artwork cache?", isPresented: $showClearArtworkConfirm) {
                    Button("Clear", role: .destructive) { Task { await clearArtwork() } }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Cached covers are deleted. They re-download on demand.")
                }
                .tint(.primary)
        }
        .task {
            await vm.loadData()
            await refreshUsage()
        }
        .onChange(of: cacheSettings?.maxTracks) { _, newValue in
            guard let newValue else { return }
            Task {
                await container?.audioStreamCache.setMaxTracks(newValue)
                await refreshUsage()
            }
        }
    }

    private func refreshUsage() async {
        guard let container else { return }
        usedBytes = await container.audioStreamCache.usedBytes
        trackCount = await container.audioStreamCache.trackCount
        let stats = await container.downloadService.coverCacheStats()
        coverCount = stats.count
        coverBytes = stats.bytes
    }

    private func clearStreamCache() async {
        guard let container else { return }
        isClearingCache = true
        defer { isClearingCache = false }
        await container.audioStreamCache.clearAll()
        container.dominantColorExtractor.clearCache()
        await refreshUsage()
    }

    private func clearArtwork() async {
        guard let container else { return }
        await container.downloadService.clearAllCovers()
        artworkImageCache.clearCache()
        artworkImageCache.clearRevalidationMetadata()
        await refreshUsage()
    }
}

// MARK: - Settings sub-pages

private struct PlaybackSettingsView: View {
    @Environment(\.appContainer) private var container

    var body: some View {
        Form {
            Section {
                if let stream = container?.streamSettings {
                    Picker(selection: Binding(
                        get: { stream.wifiQuality },
                        set: { stream.wifiQuality = $0 }
                    )) {
                        ForEach(StreamQuality.allCases) { quality in
                            Text(quality.displayName).tag(quality)
                        }
                    } label: {
                        Text("Quality on Wi-Fi")
                            .foregroundStyle(.primary)
                    }
                    .pickerStyle(.menu)
                    .tint(.secondary)

                    Picker(selection: Binding(
                        get: { stream.cellularQuality },
                        set: { stream.cellularQuality = $0 }
                    )) {
                        ForEach(StreamQuality.allCases) { quality in
                            Text(quality.displayName).tag(quality)
                        }
                    } label: {
                        Text("Quality on cellular")
                            .foregroundStyle(.primary)
                    }
                    .pickerStyle(.menu)
                    .tint(.secondary)
                }
            } header: {
                Text("Streaming")
            } footer: {
                Text("The server transcodes to the chosen tier for each network. Original streams your files untouched (lossless); a lighter tier saves cellular data and lowers decoding load. Applies to the next track.")
            }
            ReplayGainSettingsSection()
            CrossfadeSettingsSection()
        }
        .formStyle(.grouped)
        .navigationTitle("Playback")
        .navigationBarTitleDisplayModeInline()
    }
}

private struct IntegrationsSettingsView: View {
    var body: some View {
        Form {
            Section {
                NavigationLink {
                    ListenBrainzSettingsView()
                } label: {
                    Text("ListenBrainz")
                        .foregroundStyle(.primary)
                }
                NavigationLink {
                    AudioMuseSettingsView()
                } label: {
                    Text("AudioMuse")
                        .foregroundStyle(.primary)
                }
                NavigationLink {
                    LidarrSettingsView()
                } label: {
                    Text("Lidarr")
                        .foregroundStyle(.primary)
                }
                NavigationLink {
                    ExternalProvidersSettingsView()
                } label: {
                    Text("Open Releases In")
                        .foregroundStyle(.primary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Integrations")
        .navigationBarTitleDisplayModeInline()
    }
}

// MARK: - Application section (destructive actions)

/// Beszel-style bottom section: every destructive "clear" action in one place, plain red rows, with
/// the app version underneath.
struct ApplicationSectionView: View {
    let vm: DownloadsViewModel
    @State private var showClearAllConfirm = false

    var body: some View {
        Section {
            Button(role: .destructive) {
                showClearAllConfirm = true
            } label: {
                if vm.isClearingAll {
                    HStack(spacing: MinidiscSpacing.s) {
                        ProgressView().scaleEffect(0.8)
                        Text("Clearing…")
                    }
                } else {
                    Text("Clear all downloads")
                        .foregroundStyle(.red)
                }
            }
            .disabled(vm.isClearingAll)
        } header: {
            Text("Application")
        } footer: {
            Text("Version \(SettingsView.appVersion)")
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
        }
        .alert("Clear all downloads?", isPresented: $showClearAllConfirm) {
            Button("Clear", role: .destructive) { Task { await vm.clearAll() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every downloaded album and playlist is deleted. This can't be undone.")
        }
        .tint(.primary)
    }
}

