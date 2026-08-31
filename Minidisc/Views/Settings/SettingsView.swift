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
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Close", systemImage: "xmark") { dismiss() }
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
                NavigationLink {
                    ApplicationSettingsView()
                } label: {
                    Label("Application", systemImage: "paintbrush")
                        .foregroundStyle(.primary)
                }
            }
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
    @State private var showClearDownloadsConfirm = false
    @State private var showClearCacheConfirm = false
    @State private var showClearArtworkConfirm = false

    private var cacheSettings: CacheSettings? { container?.cacheSettings }

    var body: some View {
        let capacityBytes = cacheSettings?.capacityBytes ?? AudioStreamCache.defaultMaxBytes

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

            Button(role: .destructive) {
                showClearDownloadsConfirm = true
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
                Text("Downloads")
            } footer: {
                Text("Downloaded tracks are stored permanently and available offline.")
            }

            Section {
                LabeledContent {
                    Text(verbatim: "\(ByteCountFormatter.string(fromByteCount: usedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: capacityBytes, countStyle: .file)) · \(trackCount)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } label: {
                    Text("Used")
                        .foregroundStyle(.primary)
                }

                if let cacheSettings {
                    Stepper(
                        value: Binding(
                            get: { cacheSettings.capacityMegabytes },
                            set: { cacheSettings.capacityMegabytes = $0 }
                        ),
                        in: CacheSettings.minCapacityMegabytes...CacheSettings.maxCapacityMegabytes,
                        step: CacheSettings.capacityStepMegabytes
                    ) {
                        HStack {
                            Text("Size")
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: capacityBytes, countStyle: .file))
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
                Text("Keeps recently-played music for instant replay. Least-recently-played tracks are removed when the size limit is reached.")
            }

            LibraryIndexStorageSection()

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
                .alert("Clear all downloads?", isPresented: $showClearDownloadsConfirm) {
                    Button("Clear", role: .destructive) { Task { await vm.clearAll() } }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Every downloaded album and playlist is deleted. This can't be undone.")
                }
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
        .onChange(of: cacheSettings?.capacityMegabytes) { _, _ in
            guard let capacityBytes = cacheSettings?.capacityBytes else { return }
            Task {
                await container?.audioStreamCache.setMaxBytes(capacityBytes)
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

private enum LibraryIndexSettingsOperation: Equatable {
    case idle
    case synchronizing
    case deleting
    case fullIndex(completed: Int, total: Int)

    var isRunning: Bool { self != .idle }
}

/// Controls the complete discardable SwiftData index, not only its recommendation rows.
/// State stays local to the storage feature because no other screen drives these operations.
private struct LibraryIndexStorageSection: View {
    @Environment(\.appContainer) private var container
    @State private var usage = LibraryIndexStorageUsage.empty
    @State private var activeServerAlbumCount = 0
    @State private var operation = LibraryIndexSettingsOperation.idle
    @State private var operationTask: Task<Void, Never>?
    @State private var showDeleteConfirmation = false
    @State private var showFullIndexConfirmation = false
    @State private var errorMessage: String?

    private var fullIndexAllowed: Bool {
        guard let state = container?.serverState else { return false }
        let path = state.networkPathEvent.descriptor
        return state.hasObservedNetworkPath
            && path.isOnline
            && !path.isExpensive
            && !path.isConstrained
    }

    private var fullIndexConfirmationMessage: String {
        let scope = if activeServerAlbumCount > 0 {
            "The current index contains \(activeServerAlbumCount) albums for this server."
        } else {
            "The album count will be determined after metadata synchronization."
        }
        let warning = activeServerAlbumCount >= LibraryIndexMaintenanceService.largeLibraryAlbumThreshold
            ? " This is a large library; keep Minidisc open and connected to Wi-Fi. You can cancel and resume later."
            : " Keep Minidisc open until it finishes. You can cancel and resume later."
        return "\(scope) All metadata will be synchronized, then album recommendations will be precomputed one at a time.\(warning)"
    }

    var body: some View {
        Section {
            LabeledContent("Disk usage") {
                Text(ByteCountFormatter.string(fromByteCount: usage.persistentBytes, countStyle: .file))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            LabeledContent("Artists") {
                Text(usage.artists, format: .number)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            LabeledContent("Albums") {
                Text(usage.albums, format: .number)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            LabeledContent("Songs") {
                Text(usage.tracks, format: .number)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            LabeledContent("Playlists") {
                Text(usage.playlists, format: .number)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            LabeledContent("Album recommendations") {
                Text(usage.recommendationAlbums, format: .number)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            operationProgress

            Button {
                startSynchronization()
            } label: {
                Label {
                    Text("Synchronize index")
                        .foregroundStyle(.primary)
                } icon: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(.primary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(operation.isRunning)

            Button {
                showFullIndexConfirmation = true
            } label: {
                Label {
                    Text("Index full server")
                        .foregroundStyle(.primary)
                } icon: {
                    Image(systemName: "server.rack")
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(.primary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(operation.isRunning || !fullIndexAllowed)

            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Label {
                    Text("Delete index")
                        .foregroundStyle(.red)
                } icon: {
                    Image(systemName: "trash")
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(.red)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(operation.isRunning)
        } header: {
            Text("Library index")
        } footer: {
            Text("The index stores searchable metadata for artists, albums, songs, playlists, and album recommendations. Full indexing requires an unmetered, unconstrained connection. Downloads, favorites, and playback history are stored separately.")
        }
        .task {
            await refreshUsage()
        }
        .onDisappear {
            operationTask?.cancel()
        }
        .alert("Delete library index?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) { startDeletion() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All indexed metadata and cached album recommendations will be removed. Downloads, favorites, playlists on your server, and playback history are not affected.")
        }
        .alert("Index full server?", isPresented: $showFullIndexConfirmation) {
            Button("Start indexing") { startFullIndex() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(fullIndexConfirmationMessage)
        }
        .alert("Index operation failed", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var operationProgress: some View {
        switch operation {
        case .idle:
            EmptyView()
        case .synchronizing:
            LabeledContent("Synchronizing metadata…") {
                ProgressView()
            }
            Button("Cancel", role: .cancel) { operationTask?.cancel() }
        case .deleting:
            LabeledContent("Deleting index…") {
                ProgressView()
            }
        case .fullIndex(let completed, let total):
            VStack(alignment: .leading, spacing: MinidiscSpacing.s) {
                if total > 0 {
                    ProgressView(value: Double(completed), total: Double(total))
                    Text("\(completed) of \(total) albums")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    HStack {
                        Text("Synchronizing metadata…")
                        Spacer()
                        ProgressView()
                    }
                }
            }
            Button("Cancel", role: .cancel) { operationTask?.cancel() }
        }
    }

    private func startSynchronization() {
        guard let maintenance = container?.libraryIndexMaintenance else { return }
        operationTask = Task { @MainActor in
            operation = .synchronizing
            defer {
                operation = .idle
                operationTask = nil
            }
            do {
                try await maintenance.synchronize()
                await refreshUsage()
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func startFullIndex() {
        guard let maintenance = container?.libraryIndexMaintenance else { return }
        operationTask = Task { @MainActor in
            operation = .fullIndex(completed: 0, total: 0)
            defer {
                operation = .idle
                operationTask = nil
            }
            do {
                try await maintenance.indexFullServer { progress in
                    switch progress {
                    case .synchronizingMetadata:
                        operation = .fullIndex(completed: 0, total: 0)
                    case .indexingRecommendations(let completed, let total):
                        operation = .fullIndex(completed: completed, total: total)
                    }
                }
                await refreshUsage()
            } catch is CancellationError {
                await refreshUsage()
            } catch {
                await refreshUsage()
                errorMessage = error.localizedDescription
            }
        }
    }

    private func startDeletion() {
        guard let maintenance = container?.libraryIndexMaintenance else { return }
        operationTask = Task { @MainActor in
            operation = .deleting
            defer {
                operation = .idle
                operationTask = nil
            }
            do {
                try await maintenance.eraseAll()
                await refreshUsage()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func refreshUsage() async {
        guard let maintenance = container?.libraryIndexMaintenance else { return }
        do {
            usage = try await maintenance.usage()
            activeServerAlbumCount = (try? await maintenance.activeServerAlbumCount()) ?? 0
        } catch {
            errorMessage = error.localizedDescription
        }
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
            if let lyrics = container?.lyricsSettings {
                LyricsSettingsSection(settings: lyrics)
            }
            ReplayGainSettingsSection()
            CrossfadeSettingsSection()
        }
        .formStyle(.grouped)
        .navigationTitle("Playback")
        .navigationBarTitleDisplayModeInline()
    }
}

private struct LyricsSettingsSection: View {
    @Bindable var settings: LyricsSettings

    var body: some View {
        Section {
            Picker(selection: $settings.source) {
                ForEach(LyricsSource.allCases) { source in
                    Text(source.displayName).tag(source)
                }
            } label: {
                Text("Lyrics source")
                    .foregroundStyle(.primary)
            }
            .pickerStyle(.menu)
            .tint(.secondary)
        } header: {
            Text("Lyrics")
        } footer: {
            Text("Auto checks Navidrome first and falls back to LRCLIB. LRCLIB requests include the track title, artist, album, and duration.")
        }
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

// MARK: - Application

/// Appearance and display preferences. Everything here is a pure UI preference, so it lives in
/// `@AppStorage` rather than the container — the same keys are read directly by `MainTabView`.
private struct ApplicationSettingsView: View {
    @AppStorage("minidisc.appTheme") private var theme: AppTheme = .system

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: $theme) {
                    ForEach(AppTheme.allCases, id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                }
                .tint(.primary)
            } header: {
                Text("Appearance")
            } footer: {
                Text("System follows your device's light or dark setting.")
            }
            ApplicationDebugSection()
        }
        .formStyle(.grouped)
        .navigationTitle("Application")
        .navigationBarTitleDisplayModeInline()
    }
}

private struct ApplicationDebugSection: View {
    var body: some View {
        Section("Debug") {
            NavigationLink {
                PlaybackDiagnosticsView()
            } label: {
                Label("Playback Diagnostics", systemImage: "waveform.badge.magnifyingglass")
                    .foregroundStyle(.primary)
            }
        }
    }
}
