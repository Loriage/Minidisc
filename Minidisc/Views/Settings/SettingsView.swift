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
                                .foregroundStyle(.secondary)
                        }
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
            streamingSection()
            ReplayGainSettingsSection()
            CrossfadeSettingsSection()
            CacheSectionView()
            DownloadsSectionView(vm: downloadsVM)
            integrationsSection()
            advancedSection()
            aboutSection()
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

    private func streamingSection() -> some View {
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
                    Label("Quality on Wi-Fi", systemImage: "wifi")
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
                    Label("Quality on cellular", systemImage: "antenna.radiowaves.left.and.right")
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
    }

    private func advancedSection() -> some View {
        Section {
            if let settings = container?.playbackEngineSettings {
                Picker(selection: Binding(
                    get: { settings.engine },
                    set: { settings.engine = $0 }
                )) {
                    ForEach(PlaybackEngine.allCases) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                } label: {
                    Label("Playback engine", systemImage: "waveform")
                        .foregroundStyle(.primary)
                }
                .pickerStyle(.menu)
                .tint(.secondary)
            }
        } header: {
            Text("Advanced")
        } footer: {
            Text("AVPlayer (System) is the default: Apple's hardware decoders give bit-perfect lossless without the software-decode crackle, with native format coverage. AudioStreaming is a software-decoding fallback. Restart the app to apply.")
        }
    }

    private func integrationsSection() -> some View {
        Section("Integrations") {
            NavigationLink {
                ListenBrainzSettingsView()
            } label: {
                Label("ListenBrainz", systemImage: "link.circle")
                    .foregroundStyle(.primary)
            }
            NavigationLink {
                AudioMuseSettingsView()
            } label: {
                Label("AudioMuse", systemImage: "waveform.badge.magnifyingglass")
                    .foregroundStyle(.primary)
            }
            NavigationLink {
                LidarrSettingsView()
            } label: {
                Label("Lidarr", systemImage: "square.and.arrow.down.on.square")
                    .foregroundStyle(.primary)
            }
            NavigationLink {
                ExternalProvidersSettingsView()
            } label: {
                Label("Open Releases In", systemImage: "arrow.up.right.square")
                    .foregroundStyle(.primary)
            }
        }
    }

    private static var appVersion: String {
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
        } footer: {
            Text("Version \(Self.appVersion)")
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
        }
    }
}

// MARK: - Cache section

struct CacheSectionView: View {
    @Environment(\.appContainer) private var container
    @State private var usedBytes: Int64 = 0
    @State private var trackCount: Int = 0
    @State private var isClearing: Bool = false

    private var cacheSettings: CacheSettings? { container?.cacheSettings }

    var body: some View {
        let maxTracks = cacheSettings?.maxTracks ?? 10

        return Section {
            LabeledContent {
                Text(usageDescription(maxTracks: maxTracks))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } label: {
                Label("Used", systemImage: "externaldrive")
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
                        Label("Max tracks", systemImage: "tray.full")
                            .foregroundStyle(.primary)
                        Spacer()
                        Text("\(maxTracks)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .font(.body.weight(.medium))
                    }
                }
            }

            if let cacheSettings {
                Picker(selection: Binding<CacheFormat>(
                    get: { cacheSettings.cacheFormat },
                    set: { newValue in cacheSettings.cacheFormat = newValue }
                )) {
                    ForEach(CacheFormat.allCases) { format in
                        Text(format.displayName).tag(format)
                    }
                } label: {
                    Label("Format", systemImage: "waveform")
                        .foregroundStyle(.primary)
                }
                .pickerStyle(.menu)
                .tint(.secondary)
            }

            if let cacheSettings {
                Toggle(isOn: Binding(
                    get: { cacheSettings.cacheOverCellular },
                    set: { cacheSettings.cacheOverCellular = $0 }
                )) {
                    Label("Use cellular data", systemImage: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(.primary)
                }
                .tint(Color(.systemGreen))
            }

            Button(role: .destructive) {
                Task { await clearCache() }
            } label: {
                if isClearing {
                    HStack(spacing: MinidiscSpacing.s) {
                        ProgressView().scaleEffect(0.8)
                        Text("Clearing…")
                    }
                } else {
                    Label("Clear cache", systemImage: "trash")
                        .foregroundStyle(.red)
                }
            }
            .disabled(isClearing || (usedBytes == 0 && trackCount == 0))

        } header: {
            Text("Cache")
        } footer: {
            Text("Cached tracks let recently-played music load instantly without re-fetching from the server. Cache is automatic, sliding window — the oldest track is replaced when the limit is reached.")
        }
        .task {
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

    // MARK: - Helpers

    private func usageDescription(maxTracks: Int) -> String {
        let bytesString = ByteCountFormatter.string(fromByteCount: usedBytes, countStyle: .file)
        return "\(bytesString) · \(trackCount)/\(maxTracks) tracks"
    }

    private func refreshUsage() async {
        guard let container else { return }
        let bytes = await container.audioStreamCache.usedBytes
        let count = await container.audioStreamCache.trackCount
        usedBytes = bytes
        trackCount = count
    }

    private func clearCache() async {
        guard let container else { return }
        isClearing = true
        defer { isClearing = false }
        await container.audioStreamCache.clearAll()
        container.dominantColorExtractor.clearCache()
        await refreshUsage()
    }
}

// MARK: - Downloads section

struct DownloadsSectionView: View {
    let vm: DownloadsViewModel

    var body: some View {
        Section {
            LabeledContent {
                Text(vm.usedBytesFormatted)
                    .foregroundStyle(.secondary)
            } label: {
                Label("Used", systemImage: "arrow.down.circle")
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
                    Label("Albums (\(vm.displayAlbums.count))", systemImage: "music.note.list")
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
                    Label("Playlists (\(vm.downloadedPlaylists.count))", systemImage: "list.bullet")
                        .foregroundStyle(.primary)
                }
            }

            if vm.displayAlbums.isEmpty && vm.downloadedPlaylists.isEmpty {
                Text("No downloaded content.")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            }

            Button(role: .destructive) {
                Task { await vm.clearAll() }
            } label: {
                if vm.isClearingAll {
                    HStack(spacing: MinidiscSpacing.s) {
                        ProgressView().scaleEffect(0.8)
                        Text("Clearing…")
                    }
                } else {
                    Label("Clear all downloads", systemImage: "trash")
                        .foregroundStyle(.red)
                }
            }
            .disabled(vm.isClearingAll || (vm.displayAlbums.isEmpty && vm.downloadedPlaylists.isEmpty))

        } header: {
            Text("Downloads")
        } footer: {
            Text("Downloaded tracks are stored permanently and available offline.")
        }
    }
}
