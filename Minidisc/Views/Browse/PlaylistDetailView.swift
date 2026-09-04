import SwiftUI
import SwiftSonic
import SwiftData
import OSLog
import UniformTypeIdentifiers

/// Local ordering for the track list. Release date is absent on purpose: `DisplayableSong` carries no year.
enum PlaylistSortOrder: String, CaseIterable, Identifiable {
    case playlistOrder
    case title
    case artist
    case album

    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .playlistOrder: "Playlist Order"
        case .title: "Title"
        case .artist: "Artist"
        case .album: "Album"
        }
    }
}

struct PlaylistDetailView: View {
    private let playlistId: String
    private let initialName: String
    private let coverArtId: String?
    private let initialDominantColor: Color
    private let initialCoverImage: PlatformImage?
    private let zoomSourceId: String?
    private let zoomNamespace: Namespace.ID?

    init(playlist: Playlist, coverArtId: String? = nil, initialDominantColor: Color = .clear, initialCoverImage: PlatformImage? = nil, zoomSourceId: String? = nil, zoomNamespace: Namespace.ID? = nil) {
        playlistId = playlist.id
        initialName = playlist.name
        self.coverArtId = coverArtId
        self.initialDominantColor = initialDominantColor
        self.initialCoverImage = initialCoverImage
        self.zoomSourceId = zoomSourceId
        self.zoomNamespace = zoomNamespace
        let pid = playlist.id
        _downloadedPlaylistMatches = Query(filter: #Predicate<DownloadedPlaylist> { $0.playlistId == pid })
        _dominantColor = State(initialValue: initialDominantColor)
    }

    init(playlist: DownloadedPlaylist, coverArtId: String? = nil, initialDominantColor: Color = .clear, initialCoverImage: PlatformImage? = nil, zoomSourceId: String? = nil, zoomNamespace: Namespace.ID? = nil) {
        playlistId = playlist.playlistId
        initialName = playlist.name
        self.coverArtId = coverArtId
        self.initialDominantColor = initialDominantColor
        self.initialCoverImage = initialCoverImage
        self.zoomSourceId = zoomSourceId
        self.zoomNamespace = zoomNamespace
        let pid = playlist.playlistId
        _downloadedPlaylistMatches = Query(filter: #Predicate<DownloadedPlaylist> { $0.playlistId == pid })
        _dominantColor = State(initialValue: initialDominantColor)
    }

    init(playlistId: String, name: String, coverArtId: String? = nil, initialDominantColor: Color = .clear, initialCoverImage: PlatformImage? = nil, zoomSourceId: String? = nil, zoomNamespace: Namespace.ID? = nil) {
        self.playlistId = playlistId
        self.initialName = name
        self.coverArtId = coverArtId
        self.initialDominantColor = initialDominantColor
        self.initialCoverImage = initialCoverImage
        self.zoomSourceId = zoomSourceId
        self.zoomNamespace = zoomNamespace
        let pid = playlistId
        _downloadedPlaylistMatches = Query(filter: #Predicate<DownloadedPlaylist> { $0.playlistId == pid })
        _dominantColor = State(initialValue: initialDominantColor)
    }

    @Environment(\.appContainer) private var container
    @Environment(PlaylistAddition.self) private var playlistAddition
    @Environment(\.dismiss) private var dismiss
    @Environment(DominantColorExtractor.self) private var colorExtractor
    @Environment(\.colorScheme) private var colorScheme
    @State private var viewModel: PlaylistDetailViewModel?
    @State private var dominantColor: Color = .clear
    @State private var gradientSpec: PlaylistGradientSpec?
    @State private var localCoverId: String?
    @State private var showThemeColorSheet = false
    @State private var sortOrder: PlaylistSortOrder = .playlistOrder
    @State private var showDeleteAlert = false
    @State private var showAddMusic = false

    @State private var coverRefreshID = UUID()

    // MARK: - In-place edit mode

    @State private var isEditing = false
    @State private var editName: String = ""
    @State private var editComment: String = ""
    @State private var editSongs: [DisplayableSong] = []
    @State private var selectedSongIds: Set<String> = []
    @State private var selectedGradient: PlaylistGradientShape?
    @State private var photoIsCover = false
    @State private var coverDirty = false
    @State private var showDeletePlaylistConfirm = false
    @State private var showRemoveSongsConfirm = false
    @State private var isSaving = false
    @State private var pendingImage: UIImage?
    @State private var showImageOptions = false
    @State private var showImagePicker = false
    @State private var showCamera = false
    @State private var showFilePicker = false
    @State private var imageToCrop: CroppableImage?

    @State private var heroHeight: CGFloat = 680

    // SwiftData remains the fallback when the online view model has no songs.
    @Query private var downloadedPlaylistMatches: [DownloadedPlaylist]
    @Query private var allDownloadedTracks: [DownloadedTrack]

    private var effectiveCoverArtId: String { viewModel?.coverArtId ?? coverArtId ?? playlistId }
    private var displayCoverArtId: String { localCoverId ?? effectiveCoverArtId }
    /// Every id the playlist theme can be keyed on, so the override resolves whichever cover id a surface uses.
    /// Track cover ids are deliberately excluded — they belong to albums that must keep their own colour.
    private var playlistThemeIds: [String] {
        Array(Set([displayCoverArtId, effectiveCoverArtId, playlistId]))
    }
    /// Drops the manual override and falls back to the gradient's own colour, else the one taken from the cover.
    private func resetThemeColor() {
        colorExtractor.setColorOverride(nil, forIds: playlistThemeIds)
        dominantColor = gradientSpec?.baseColor ?? colorExtractor.cachedColor(for: displayCoverArtId) ?? dominantColor
    }

    private var theme: PlaylistTheme { PlaylistTheme(dominantColor: dominantColor) }
    private var headerTextColor: Color { theme.contentColor }
    private var headerSecondaryColor: Color { theme.secondaryContentColor }

    private var bodyColor: Color {
        if theme.isThemed { return theme.dominantColor }
        return Color(UIColor.systemBackground)
    }

    private func metadataLine(count: Int, updated: Date?) -> String {
        var parts = [String(localized: "\(count) songs")]
        if let updated {
            parts.append("Updated \(updated.formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: " · ")
    }
    private var heroIconColor: Color {
        colorScheme == .dark ? Color.minidiscAccentSecondary : MinidiscColors.accentForeground(on: dominantColor)
    }
    private var isLoadingSkeleton: Bool {
        viewModel == nil || (viewModel?.isLoading == true && viewModel?.songs.isEmpty == true)
    }

    private var downloadedFallbackSongs: [DisplayableSong] {
        guard let serverId = container?.serverState.activeServer?.id,
              let record = downloadedPlaylistMatches.first(where: { $0.serverId == serverId })
        else { return [] }
        let bySongId = Dictionary(
            allDownloadedTracks.filter { $0.serverId == serverId }.map { ($0.songId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return record.songIds.compactMap { bySongId[$0] }.map { DisplayableSong(from: $0) }
    }

    /// The order the list and playback follow. Purely local — the stored order is untouched, so edit / remove
    /// keep working against the real positions.
    private func sortedSongs(_ songs: [DisplayableSong]) -> [DisplayableSong] {
        switch sortOrder {
        case .playlistOrder:
            return songs
        case .title:
            return songs.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .artist:
            return songs.sorted { ($0.artist ?? "").localizedStandardCompare($1.artist ?? "") == .orderedAscending }
        case .album:
            return songs.sorted { ($0.albumName ?? "").localizedStandardCompare($1.albumName ?? "") == .orderedAscending }
        }
    }

    private func playSongs(_ requested: [DisplayableSong], startIndex: Int) async {
        guard requested.indices.contains(startIndex), let vm = viewModel, let container else { return }
        let selectedID = requested[startIndex].id
        do {
            try await container.playerService.play(preparingQueue: {
                let refreshed = await vm.playbackSongs(from: requested)
                guard let index = refreshed.firstIndex(where: { $0.id == selectedID }) else {
                    throw UserFacingError.contentRemoved
                }
                return PreparedPlaybackQueue(tracks: refreshed, startIndex: index)
            })
        } catch {
            if !UserFacingError.isCancellation(error), !vm.isRemovedFromServer {
                container.toastService.showError(UserFacingError.from(error).displayMessage)
            }
        }
    }

    private func resolvedSongs(_ vm: PlaylistDetailViewModel?) -> [DisplayableSong] {
        if vm?.isRemovedFromServer == true { return vm?.songs ?? [] }
        if let songs = vm?.songs, !songs.isEmpty { return songs }
        return downloadedFallbackSongs
    }

    var body: some View {
        // List is required for swipe-to-remove.
        List(selection: $selectedSongIds) {
            Group {
                if isEditing {
                    editHeader
                        .transition(.opacity)
                } else {
                    playlistHeader(vm: viewModel)
                        .transition(.opacity)
                }
            }
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            if isLoadingSkeleton {
                skeletonRows
            } else if isEditing {
                editableSongRows
            } else if let vm = viewModel {
                let songs = sortedSongs(resolvedSongs(vm))
                if vm.isRemovedFromServer {
                    VStack(alignment: .leading, spacing: MinidiscSpacing.s) {
                        Label("Playlist removed from server", systemImage: "music.note.list")
                            .font(.headline)
                        Text(songs.isEmpty
                             ? String(localized: "This playlist is no longer available. Choose another playlist to continue listening.")
                             : String(localized: "This playlist is no longer on the server. Your downloaded songs are still available."))
                            .font(.subheadline)
                        Button("Back to Library") {
                            NotificationCenter.default.post(name: .minidiscNavigateToLibrary, object: nil)
                        }
                            .frame(minHeight: 44)
                    }
                    .foregroundStyle(headerTextColor)
                    .listRowSeparator(.hidden)
                    .listRowBackground(bodyColor)
                }
                if songs.isEmpty, vm.isRemovedFromServer {
                    EmptyView()
                } else if songs.isEmpty, let error = vm.error {
                    EmptyStateView(
                        systemImage: "exclamationmark.triangle",
                        title: "Unable to Load Playlist",
                        subtitle: LocalizedStringKey(error.displayMessage),
                        action: .init(label: "Retry") { Task { await vm.load() } }
                    )
                    .listRowSeparator(.hidden)
                    .listRowBackground(bodyColor)
                } else if songs.isEmpty {
                    EmptyStateView(
                        systemImage: "music.note.list",
                        title: "Empty Playlist",
                        subtitle: "This playlist doesn't have any tracks yet."
                    )
                    .listRowSeparator(.hidden)
                    .listRowBackground(bodyColor)
                } else {
                    let serverId = container?.serverState.activeServer?.id ?? UUID()
                    // Rows are displayed in the sorted order, the view model removes by stored position.
                    let removeTrack: ((Int) -> Void)? = vm.isOffline ? nil : { index in
                        guard songs.indices.contains(index) else { return }
                        let song = songs[index]
                        guard let stored = resolvedSongs(vm).firstIndex(where: { $0.id == song.id }) else { return }
                        Task { await vm.removeTrack(at: stored) }
                    }
                    PlaylistSongRows(
                        songs: songs,
                        serverId: serverId,
                        downloadingIds: vm.downloadingIds,
                        titleColor: headerTextColor,
                        secondaryColor: headerSecondaryColor,
                        onTap: { index in
                            Task {
                                await playSongs(songs, startIndex: index)
                            }
                        },
                        onDownload: (vm.isOffline || vm.isDownloadingPlaylist) ? nil : { songId in
                            Task { await vm.downloadSong(id: songId) }
                        },
                        onRemoveDownload: { songId in
                            Task { await container?.toastService.perform { try await container?.downloadService.remove(songId: songId, serverId: serverId) } }
                        },
                        onRemove: removeTrack,
                        onContextRemove: removeTrack,
                        onAddToPlaylist: playlistAddition.present,
                        rowBackground: bodyColor
                    )

                    let featured = FeaturedArtist.from(songs)
                    if !featured.isEmpty {
                        featuredArtistsSection(featured)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .listRowBackground(bodyColor)
                    }
                }
            }
        }
        .listStyle(.plain)
        // Supplying an inactive edit binding prevents normal List scrolling.
        .environment(\.editMode, isEditing ? Binding.constant(EditMode.active) : nil)
        .scrollContentBackground(.hidden)
        .ignoresSafeArea(.container, edges: .top)
        .minidiscHideTopScrollEdgeEffect()
        .miniPlayerBottomMargin()
        .refreshable { await viewModel?.load() }
        .alert("Remove downloaded playlist?", isPresented: $showDeleteAlert) {
            Button("Remove", role: .destructive) { Task { await viewModel?.deleteDownload() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The audio files will be deleted from this device.")
        }
        .confirmationDialog("Cover Art", isPresented: $showImageOptions, titleVisibility: .visible) {
            Button("Choose from Library") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { showImagePicker = true }
            }
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("Take a Photo") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { showCamera = true }
                }
            }
            Button("Browse Files") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { showFilePicker = true }
            }
            Button("Cancel", role: .cancel) {}
        }
        .fullScreenCover(isPresented: $showImagePicker) {
            ImagePickerController(sourceType: .photoLibrary, allowsEditing: false, onPick: { presentCrop($0) }, onCancel: {})
                .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $showCamera) {
            ImagePickerController(sourceType: .camera, allowsEditing: false, onPick: { presentCrop($0) }, onCancel: {})
                .ignoresSafeArea()
        }
        .fullScreenCover(item: $imageToCrop) { croppable in
            SquareCropView(image: croppable.image, onCrop: { pendingImage = $0; imageToCrop = nil }, onCancel: { imageToCrop = nil })
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.jpeg, .png, .heic, .webP], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url), let img = UIImage(data: data) { presentCrop(img) }
        }
        .deletePlaylistConfirmation(
            playlistName: viewModel?.name ?? initialName,
            isPresented: $showDeletePlaylistConfirm,
            hasDownloads: (viewModel?.songs.contains { $0.isDownloaded } ?? false) || !downloadedPlaylistMatches.isEmpty
        ) { purgeDownloads in
            Task { await deletePlaylistInPlace(purgeDownloads: purgeDownloads) }
        }
        .alert("Remove \(selectedSongIds.count) Songs?", isPresented: $showRemoveSongsConfirm) {
            Button("Remove", role: .destructive) { removeSelectedTracks() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They'll be removed from the playlist when you save.")
        }
        .sheet(isPresented: $showThemeColorSheet) {
            ThemeColorSheet(
                color: Binding(
                    get: { colorExtractor.cachedColor(for: displayCoverArtId) ?? dominantColor },
                    set: { newColor in
                        colorExtractor.setColorOverride(newColor, forIds: playlistThemeIds)
                        dominantColor = newColor
                    }
                ),
                hasOverride: colorExtractor.colorOverride(for: displayCoverArtId) != nil,
                footerText: "Overrides the colour taken from the cover, here and anywhere else this playlist appears.",
                onReset: resetThemeColor
            )
        }
        .sheet(isPresented: $showAddMusic) {
            if let vm = viewModel, let c = container, let serverId = c.serverState.activeServer?.id {
                AddMusicSheet(
                    playlistName: vm.name,
                    existingTrackIds: resolvedSongs(vm).map(\.id)
                ) { added in
                    await AddMusicCommitter.commit(
                        addedSongs: added,
                        playlistId: playlistId,
                        playlistName: vm.name,
                        coverArtId: effectiveCoverArtId,
                        serverId: serverId,
                        existingTrackIds: resolvedSongs(vm).map(\.id),
                        currentComment: vm.playlistDetail?.comment ?? "",
                        container: c,
                        colorExtractor: colorExtractor
                    )
                    await vm.load()
                    coverRefreshID = UUID()
                }
                .environment(colorExtractor)
                .environment(c.artworkImageCache)
                .environment(\.appContainer, c)
            }
        }
        .background(bodyColor.ignoresSafeArea())
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { heroHeight = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, w in heroHeight = w }
            }
        }
        .minidiscContentWidth()
        .environment(\.minidiscPlayingAccent, heroIconColor)
        .navigationTitle("")
        .navigationBarTitleDisplayModeInline()
        .navigationBarBackButtonHidden(true)
        .enableSwipeBack()
        .toolbar { toolbarContent }
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(theme.isThemed ? (theme.isLight ? .light : .dark) : nil, for: .navigationBar)
        .task(id: container?.serverState.isOnline) {
            guard let c = container else { return }
            if viewModel == nil {
                viewModel = PlaylistDetailViewModel(
                    playlistId: playlistId,
                    libraryService: c.libraryService,
                    downloadService: c.downloadService,
                    playlistService: c.playlistService,
                    toastService: c.toastService,
                    serverState: c.serverState
                )
            }
            await viewModel?.load()
        }
        .task(id: effectiveCoverArtId) {
            guard gradientSpec == nil else { return }
            let artId = effectiveCoverArtId
            let cached = colorExtractor.dominantColor(for: artId, image: nil)
            if cached != .clear {
                dominantColor = cached
                return
            }
            await loadDominantColor(coverArtId: artId)
        }
        .task(id: coverRefreshID) {
            if let downloadService = container?.downloadService {
                localCoverId = await PlaylistCoverManager.localCoverId(
                    playlistId: playlistId,
                    downloadService: downloadService
                )
            }
            guard let container, let serverId = container.serverState.activeServer?.id else { gradientSpec = nil; return }
            let choice = PlaylistCoverStore(modelContainer: container.modelContainer).choice(playlistId: playlistId, serverId: serverId)
            let spec = choice?.isUserPicked == true ? choice?.spec : nil
            gradientSpec = spec
            if let spec {
                let color = colorExtractor.colorOverride(for: displayCoverArtId) ?? spec.baseColor
                withAnimation(.easeIn(duration: 0.2)) { dominantColor = color }
            }
        }
        .minidiscZoomTransition(sourceID: zoomSourceId, in: zoomNamespace)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if isEditing {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", systemImage: "xmark") { cancelEdit() }
                    .tint(.primary)
                    .disabled(isSaving)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Delete", systemImage: "trash", role: .destructive) {
                    if selectedSongIds.isEmpty { showDeletePlaylistConfirm = true } else { showRemoveSongsConfirm = true }
                }
                .tint(.red)
                .disabled(isSaving)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Add Music", systemImage: "plus") { showAddMusic = true }
                    .tint(.primary)
                    .disabled(isSaving || container?.serverState.isOnline != true)
            }
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView().controlSize(.small).tint(.primary)
                } else {
                    let canSave = !editName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    Button("Save", systemImage: "checkmark") { Task { isSaving = true; await commitEdit(); isSaving = false } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canSave)
                }
            }
        } else {
            ToolbarItem(placement: .navigation) {
                Button("Back", systemImage: "chevron.left") {
                    dismiss()
                }
                .tint(.primary)
            }
            ToolbarItem(placement: .primaryAction) {
                Menu("More options", systemImage: "ellipsis") {
                    Group {
                        let canEdit = container?.serverState.isOnline == true && viewModel?.playlistDetail != nil
                        Button("Add Music", systemImage: "plus") {
                            showAddMusic = true
                        }
                        .disabled(!canEdit)
                        Button("Edit", systemImage: "pencil") {
                            enterEdit()
                        }
                        .disabled(!canEdit)
                        Divider()
                        Menu {
                            Picker("Sort By", selection: $sortOrder) {
                                ForEach(PlaylistSortOrder.allCases) { order in
                                    Text(order.label).tag(order)
                                }
                            }
                        } label: {
                            Label("Sort By", systemImage: "arrow.up.arrow.down")
                        }
                        Divider()
                        Button("Theme colour", systemImage: "paintpalette") {
                            showThemeColorSheet = true
                        }
                        if colorExtractor.colorOverride(for: displayCoverArtId) != nil {
                            Button("Reset to cover colour", systemImage: "arrow.uturn.backward") {
                                resetThemeColor()
                            }
                        }
                    }
                    .tint(.primary)
                }
                .tint(.primary)
            }
        }
    }

    // MARK: - Skeleton rows (list-compatible; kept with listRow modifiers since List is preserved)

    @ViewBuilder
    private var skeletonRows: some View {
        ForEach(0..<5, id: \.self) { _ in
            HStack(spacing: MinidiscSpacing.m) {
                SkeletonBlock(width: 20, height: 20, cornerRadius: 4)
                VStack(alignment: .leading, spacing: 6) {
                    SkeletonBlock(width: 200, height: 16, cornerRadius: 4)
                    SkeletonBlock(width: 140, height: 12, cornerRadius: 4)
                }
                Spacer()
            }
            .padding(.vertical, MinidiscSpacing.xs)
            .listRowInsets(EdgeInsets(top: 0, leading: MinidiscSpacing.l, bottom: 0, trailing: MinidiscSpacing.l))
            .listRowBackground(bodyColor)
            .listRowSeparator(.hidden)
        }
    }

    // MARK: - Color loading

    private func loadDominantColor(coverArtId: String) async {
        guard let image = await container?.artworkImageCache.load(coverArtId: coverArtId) else { return }
        let color = colorExtractor.dominantColor(for: coverArtId, image: image)
        withAnimation(.easeIn(duration: 0.2)) {
            dominantColor = color
        }
    }

    // MARK: - Download state helpers

    private func downloadState(for vm: PlaylistDetailViewModel) -> PlaylistDownloadState {
        let total = vm.songs.count
        guard total > 0 else { return .notDownloaded }
        let downloaded = vm.songs.filter { $0.isDownloaded }.count
        if downloaded == 0 { return .notDownloaded }
        if downloaded == total { return .fullyDownloaded }
        return .partiallyDownloaded(downloaded: downloaded, total: total)
    }

    // MARK: - In-place edit header (iOS in-place editor; reuses the validated carousel + fields)

    private var editHeader: some View {
        VStack(spacing: MinidiscSpacing.xl) {
            editCoverCarousel
                // Clear the (edit-mode) nav bar since the list bleeds under it via ignoresSafeArea(.top).
                .padding(.top, 100)
            VStack(spacing: MinidiscSpacing.s) {
                TextField("Playlist Title", text: $editName)
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .padding(.vertical, MinidiscSpacing.s)
                TextField("Description", text: $editComment, axis: .vertical)
                    .multilineTextAlignment(.center)
                    .lineLimit(1...4)
            }
            .padding(.horizontal, MinidiscSpacing.l)
        }
        .padding(.bottom, MinidiscSpacing.l)
    }

    private var editCoverCarousel: some View {
        PlaylistCoverCarousel(
            title: editName,
            selectedGradient: selectedGradient,
            isPhotoSelected: photoIsCover,
            photoPreview: editPhotoPreview,
            showsPhotoOption: editShowsPhotoOption,
            leadingLabel: "Current",
            leadingCoverArtId: displayCoverArtId,
            onSelectLeading: {
                selectedGradient = nil
                photoIsCover = false
                coverDirty = true
            },
            onSelectPhoto: {
                selectedGradient = nil
                photoIsCover = true
                coverDirty = true
            },
            onRequestPhotoPicker: {
                selectedGradient = nil
                photoIsCover = true
                coverDirty = true
                showImageOptions = true
            },
            onSelectGradient: { shape in
                selectedGradient = shape
                photoIsCover = false
                coverDirty = true
            }
        )
    }

    private var editShowsPhotoOption: Bool {
        return true
    }

    private var editPhotoPreview: PlatformImage? {
        return pendingImage
    }

    private func enterEdit() {
        editName = viewModel?.name ?? initialName
        editComment = viewModel?.playlistDetail?.comment ?? ""
        editSongs = resolvedSongs(viewModel)
        selectedSongIds = []
        selectedGradient = nil
        photoIsCover = false
        coverDirty = false
        pendingImage = nil
        loadEditGradientChoice()
        withAnimation(.smooth) { isEditing = true }
    }

    private func cancelEdit() {
        withAnimation(.smooth) { isEditing = false }
    }

    private func commitEdit() async {
        guard let c = container, let serverId = c.serverState.activeServer?.id else {
            container?.toastService.showError(UserFacingError.serverUnreachable.displayMessage)
            return
        }
        let trimmedName = editName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedComment = editComment.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentName = viewModel?.name ?? initialName
        let currentComment = viewModel?.playlistDetail?.comment ?? ""
        let commentChanged = trimmedComment != currentComment.trimmingCharacters(in: .whitespacesAndNewlines)
        let originalSongs = resolvedSongs(viewModel)
        let songsChanged = editSongs.map(\.id) != originalSongs.map(\.id)

        let nameChanged = !trimmedName.isEmpty && trimmedName != currentName.trimmingCharacters(in: .whitespacesAndNewlines)
        let edits = PlaylistEdits(
            name: nameChanged ? trimmedName : nil,
            orderedSongIDs: songsChanged ? editSongs.map(\.id) : nil,
            description: songsChanged || commentChanged ? trimmedComment : nil
        )
        guard await c.toastService.perform({
            try await PlaylistEditCommitter.commit(edits, playlistID: playlistId, service: c.playlistService)
        }) else {
            // Leave the editor and all draft fields intact so Save can retry the same snapshot.
            return
        }
        if coverDirty {
            await applyCoverInPlace(container: c, serverId: serverId, originalSongs: originalSongs)
        } else if nameChanged {
            await rebakeGradientTitle(container: c, serverId: serverId, title: trimmedName)
        }
        await AddMusicCommitter.deriveFirstTrackCoverIfNeeded(
            wasEmpty: originalSongs.isEmpty,
            firstSong: editSongs.first,
            playlistId: playlistId,
            playlistName: editName,
            coverArtId: effectiveCoverArtId,
            serverId: serverId,
            container: c,
            colorExtractor: colorExtractor
        )
        await viewModel?.load()
        coverRefreshID = UUID()
        withAnimation(.smooth) { isEditing = false }
    }

    /// A gradient cover carries the playlist title as pixels, so a rename has to re-render it.
    private func rebakeGradientTitle(container c: AppContainer, serverId: UUID, title: String) async {
        let store = PlaylistCoverStore(modelContainer: c.modelContainer)
        guard let choice = store.choice(playlistId: playlistId, serverId: serverId),
              choice.isUserPicked, let spec = choice.spec else { return }
        let manager = PlaylistCoverManager(
            downloadService: c.downloadService,
            artworkImageCache: c.artworkImageCache
        )
        await manager.applyGradientCover(spec, playlistId: playlistId, title: title, coverArtId: effectiveCoverArtId)
    }

    private func applyCoverInPlace(container c: AppContainer, serverId: UUID, originalSongs: [DisplayableSong]) async {
        let manager = PlaylistCoverManager(
            downloadService: c.downloadService,
            artworkImageCache: c.artworkImageCache
        )
        let store = PlaylistCoverStore(modelContainer: c.modelContainer)
        if let shape = selectedGradient {
            let spec = await PlaylistGradientResolver.resolve(
                form: shape,
                firstTrackCoverArtId: originalSongs.first?.coverArtId,
                artworkImageCache: c.artworkImageCache,
                colorExtractor: colorExtractor
            )
            await manager.applyGradientCover(spec, playlistId: playlistId, title: editName, coverArtId: effectiveCoverArtId)
            store.save(spec, playlistId: playlistId, serverId: serverId, isUserPicked: true)
            return
        }
        if photoIsCover, let image = pendingImage, let data = image.jpegData(compressionQuality: 0.85) {
            await manager.applyImageCover(data, playlistId: playlistId, coverArtId: effectiveCoverArtId)
            store.remove(playlistId: playlistId, serverId: serverId)
        }
    }

    // MARK: - Editable track list

    @ViewBuilder
    private var editableSongRows: some View {
        ForEach(editSongs) { song in
            editTrackRow(song)
                .tag(song.id)
                .listRowBackground(bodyColor)
                .environment(\.colorScheme, dragHandleScheme)
        }
        .onMove { from, to in
            editSongs.move(fromOffsets: from, toOffset: to)
        }
    }

    private var dragHandleScheme: ColorScheme {
        theme.isThemed ? (theme.isLight ? .light : .dark) : colorScheme
    }

    private func editTrackRow(_ song: DisplayableSong) -> some View {
        HStack(spacing: MinidiscSpacing.m) {
            CoverArtView(id: song.coverArtId ?? song.id, size: 80, cornerRadius: MinidiscCornerRadius.standard)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.minidiscCellTitle)
                    .foregroundStyle(headerTextColor)
                    .lineLimit(1)
                if let artist = song.artist {
                    Text(artist)
                        .font(.minidiscCellSubtitle)
                        .foregroundStyle(headerSecondaryColor)
                        .lineLimit(1)
                }
            }
        }
    }

    private func removeSelectedTracks() {
        editSongs.removeAll { selectedSongIds.contains($0.id) }
        selectedSongIds.removeAll()
    }

    private func deletePlaylistInPlace(purgeDownloads: Bool) async {
        guard let c = container else { return }
        do {
            try await c.playlistService.deletePlaylist(id: playlistId, purgeDownloads: purgeDownloads)
            postPlaylistDeleted()
            dismiss()
        } catch {
            Logger.playlist.error("PlaylistDetailView: in-place delete failed: \(error, privacy: .public)")
            c.toastService.showError("Failed to delete playlist")
        }
    }

    private func loadEditGradientChoice() {
        guard let c = container, let serverId = c.serverState.activeServer?.id else { return }
        if let choice = PlaylistCoverStore(modelContainer: c.modelContainer).choice(playlistId: playlistId, serverId: serverId),
           choice.isUserPicked, let spec = choice.spec {
            selectedGradient = spec.shape
        }
    }

    /// Defer presenting the crop screen so the picker fully dismisses first (sequential full-screen covers).
    private func presentCrop(_ image: UIImage) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            imageToCrop = CroppableImage(image: image)
        }
    }

    // MARK: - Header

    private func playlistHeader(vm: PlaylistDetailViewModel?) -> some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let stretch = max(0, geo.frame(in: .global).minY)
                PlaylistThemedBackground(
                    coverArtId: displayCoverArtId,
                    coverImage: initialCoverImage,
                    theme: theme,
                    heroHeight: heroHeight,
                    lightMelt: true
                )
                .frame(width: geo.size.width, height: heroHeight + stretch)
                .offset(y: -stretch)
                .id(coverRefreshID)
            }
            .frame(height: heroHeight)

            VStack(spacing: MinidiscSpacing.l) {
                VStack(spacing: 0) {
                    Text(vm?.name ?? initialName)
                    .font(.minidiscDetailTitle)
                    .foregroundStyle(headerTextColor)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, MinidiscSpacing.xs)
                if vm == nil {
                    SkeletonBlock(width: 140, height: 18, cornerRadius: 4)
                        .padding(.bottom, MinidiscSpacing.s)
                } else if let owner = vm?.owner {
                    Text("by \(owner)")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(headerSecondaryColor)
                        .padding(.bottom, MinidiscSpacing.s)
                }
                if vm == nil {
                    SkeletonBlock(width: 100, height: 14, cornerRadius: 4)
                } else if vm != nil {
                    let count = resolvedSongs(vm).count
                    Text(metadataLine(count: count, updated: vm?.playlistDetail?.changed))
                        .font(.minidiscCaption)
                        .foregroundStyle(headerSecondaryColor.opacity(0.8))
                }
            }
            .padding(.horizontal, MinidiscSpacing.l)

            Group {
                HStack(spacing: MinidiscSpacing.m) {
                    Button {
                        HapticFeedback.medium.trigger()
                        Task {
                            let shuffled = resolvedSongs(vm).shuffled()
                            guard !shuffled.isEmpty else { return }
                            await playSongs(shuffled, startIndex: 0)
                        }
                    } label: {
                        Image(systemName: "shuffle")
                            .font(.minidiscCellTitle)
                            .foregroundStyle(.white)
                            .minidiscSolidCircleButton(size: 44)
                    }
                    .disabled(resolvedSongs(vm).isEmpty)
                    .accessibilityLabel("Shuffle")
                    .opacity(vm == nil ? 0.4 : 1)

                    PlayButton(action: {
                        Task {
                            let songs = sortedSongs(resolvedSongs(vm))
                            guard !songs.isEmpty else { return }
                            await playSongs(songs, startIndex: 0)
                        }
                    }, isDisabled: resolvedSongs(vm).isEmpty, accentColor: .white, labelColor: MinidiscColors.accentForeground(on: .white), height: 44)
                    .frame(maxWidth: 220)

                    if vm?.isOffline != true {
                        if let vm {
                            if vm.isDownloadingPlaylist {
                                Button { Task { await vm.cancelPlaylistDownload() } } label: {
                                    Image(systemName: "xmark")
                                        .font(.minidiscCellTitle)
                                        .foregroundStyle(.white)
                                        .minidiscSolidCircleButton(size: 44)
                                }
                                .accessibilityLabel("Cancel Download")
                            } else {
                                switch downloadState(for: vm) {
                                case .notDownloaded:
                                    Button { Task { await vm.downloadPlaylist() } } label: {
                                        Image(systemName: "arrow.down")
                                            .font(.minidiscCellTitle)
                                            .foregroundStyle(.white)
                                            .minidiscSolidCircleButton(size: 44)
                                    }
                                    .disabled(vm.songs.isEmpty)
                                    .accessibilityLabel("Download Playlist")
                                case .partiallyDownloaded:
                                    Button { Task { await vm.downloadMissingTracks() } } label: {
                                        Image(systemName: "arrow.down")
                                            .font(.minidiscCellTitle)
                                            .foregroundStyle(.white)
                                            .minidiscSolidCircleButton(size: 44)
                                    }
                                    .accessibilityLabel("Download Missing Tracks")
                                case .fullyDownloaded:
                                    Button {
                                        HapticFeedback.heavy.trigger()
                                        showDeleteAlert = true
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.minidiscCellTitle)
                                            .foregroundStyle(.white)
                                            .minidiscSolidCircleButton(size: 44)
                                    }
                                    .accessibilityLabel("Remove Download")
                                }
                            }
                        } else {
                            Button { } label: {
                                Image(systemName: "arrow.down")
                                    .font(.minidiscCellTitle)
                                    .foregroundStyle(.white)
                                    .minidiscSolidCircleButton(size: 44)
                            }
                            .disabled(true)
                            .accessibilityLabel("Download Playlist")
                            .opacity(0.4)
                        }
                    }
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, MinidiscSpacing.l)

                if let vm, vm.isDownloadingPlaylist {
                    let serverId = container?.serverState.activeServer?.id ?? UUID()
                    PlaylistDownloadProgressView(
                        songs: vm.songs,
                        total: vm.songs.count,
                        serverId: serverId,
                        secondaryColor: headerSecondaryColor
                    )
                }
            }
            }
            .padding(.top, MinidiscSpacing.m)
            .padding(.bottom, MinidiscSpacing.xl)
        }
        .frame(maxWidth: .infinity)
    }

    /// Apple-Music "Featured Artists" rail: the most-present artists in the playlist as tappable circles
    /// → artist detail (reuses the existing `.minidiscNavigateToArtist` notification path). Only artists
    /// with an `artistId` appear (see FeaturedArtist); the circle uses a representative track cover.
    private func featuredArtistsSection(_ artists: [FeaturedArtist]) -> some View {
        VStack(alignment: .leading, spacing: MinidiscSpacing.s) {
            Text("Featured Artists")
                .font(.minidiscSectionTitle)
                .foregroundStyle(headerTextColor)
                .padding(.horizontal, MinidiscSpacing.l)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: MinidiscSpacing.m) {
                    ForEach(artists) { artist in
                        Button {
                            HapticFeedback.light.trigger()
                            postNavigateToArtist(artistId: artist.id, artistName: artist.name, coverArtId: artist.coverArtId)
                        } label: {
                            VStack(spacing: MinidiscSpacing.xs) {
                                FeaturedArtistAvatar(artist: artist, size: 76)
                                Text(artist.name)
                                    .font(.minidiscCaption)
                                    .foregroundStyle(headerSecondaryColor)
                                    .lineLimit(1)
                                    .frame(width: 84)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, MinidiscSpacing.l)
                .padding(.bottom, MinidiscSpacing.s)
            }
        }
        .padding(.top, MinidiscSpacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Download state

private nonisolated enum PlaylistDownloadState {
    case notDownloaded
    case partiallyDownloaded(downloaded: Int, total: Int)
    case fullyDownloaded
}

// MARK: - Download progress sub-view

private struct PlaylistDownloadProgressView: View {
    let songs: [DisplayableSong]
    let total: Int
    let secondaryColor: Color

    @Query private var downloadedTracks: [DownloadedTrack]

    init(songs: [DisplayableSong], total: Int, serverId: UUID, secondaryColor: Color) {
        self.songs = songs
        self.total = total
        self.secondaryColor = secondaryColor
        let sid = serverId
        _downloadedTracks = Query(filter: #Predicate<DownloadedTrack> { $0.serverId == sid })
    }

    private var downloaded: Int {
        let downloadedIds = Set(downloadedTracks.map(\.songId))
        return songs.filter { downloadedIds.contains($0.id) }.count
    }

    var body: some View {
        VStack(spacing: MinidiscSpacing.xs) {
            if downloaded == 0 {
                HStack(spacing: MinidiscSpacing.s) {
                    ProgressView().scaleEffect(0.8)
                    Text("Starting download…")
                        .font(.minidiscCaption)
                        .foregroundStyle(secondaryColor)
                }
            } else {
                ProgressView(value: Double(downloaded), total: Double(max(total, 1)))
                    .progressViewStyle(.linear)
                    .tint(Color.minidiscAccent)
                    .frame(maxWidth: 280)
                Text("Downloading \(downloaded)/\(total) tracks")
                    .font(.minidiscCaption)
                    .foregroundStyle(secondaryColor)
            }
        }
        .frame(minHeight: 44)
    }
}

// MARK: - Live download indicator rows

/// Sub-view that observes DownloadedTrack changes live via @Query,
/// overriding the isDownloaded flag per row without requiring a VM reload.
struct PlaylistSongRows: View {
    let songs: [DisplayableSong]
    let downloadingIds: Set<String>
    let titleColor: Color
    let secondaryColor: Color
    let onTap: (Int) -> Void
    let onDownload: ((String) -> Void)?
    let onRemoveDownload: ((String) -> Void)?
    let onRemove: ((Int) -> Void)?
    let onReorder: ((IndexSet, Int) -> Void)?
    let onContextRemove: ((Int) -> Void)?
    let onAddToPlaylist: ((DisplayableSong) -> Void)?
    /// Solid backing applied to EACH row so the rows occlude a fixed full-bleed cover behind the List on
    /// scroll. `nil` = default List row background.
    let rowBackground: Color?

    @Query private var downloadedTracks: [DownloadedTrack]
    @Query private var allFavorites: [FavoriteRecord]

    private var favoriteSongIds: Set<String> {
        Set(allFavorites.map(\.id))
    }

    init(songs: [DisplayableSong], serverId: UUID, downloadingIds: Set<String> = [], titleColor: Color = .primary, secondaryColor: Color = .secondary, onTap: @escaping (Int) -> Void, onDownload: ((String) -> Void)? = nil, onRemoveDownload: ((String) -> Void)? = nil, onRemove: ((Int) -> Void)? = nil, onReorder: ((IndexSet, Int) -> Void)? = nil, onContextRemove: ((Int) -> Void)? = nil, onAddToPlaylist: ((DisplayableSong) -> Void)? = nil, rowBackground: Color? = nil) {
        self.songs = songs
        self.downloadingIds = downloadingIds
        self.titleColor = titleColor
        self.secondaryColor = secondaryColor
        self.onTap = onTap
        self.onDownload = onDownload
        self.onRemoveDownload = onRemoveDownload
        self.onRemove = onRemove
        self.onReorder = onReorder
        self.onContextRemove = onContextRemove
        self.onAddToPlaylist = onAddToPlaylist
        self.rowBackground = rowBackground
        let sid = serverId
        _downloadedTracks = Query(
            filter: #Predicate<DownloadedTrack> { track in
                track.serverId == sid
            }
        )
    }

    private var downloadedSongIds: Set<String> {
        Set(downloadedTracks.map(\.songId))
    }

    var body: some View {
        if let removeAction = onRemove {
            ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                makeRow(index: index, song: song)
                    .listRowBackground(rowBackground)
            }
            .onDelete { indexSet in
                for index in indexSet.sorted(by: >) { removeAction(index) }
            }
            .onMove { source, destination in
                onReorder?(source, destination)
            }
        } else {
            ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                makeRow(index: index, song: song)
                    .listRowBackground(rowBackground)
            }
        }
    }

    @ViewBuilder
    private func makeRow(index: Int, song: DisplayableSong) -> some View {
        let liveDownloaded = downloadedSongIds.contains(song.id)
        let liveSong = song.withDownloaded(liveDownloaded)
        let isDownloading = downloadingIds.contains(song.id)
        let downloadAction: (() -> Void)? = (liveDownloaded || isDownloading) ? nil : onDownload.map { action in { action(song.id) } }
        let removeAction: (() -> Void)? = liveDownloaded ? onRemoveDownload.map { action in { action(song.id) } } : nil
        SongRow(song: liveSong, index: index + 1, showCoverArt: true, isFavorite: favoriteSongIds.contains("song:\(song.id)"), titleColor: titleColor, secondaryColor: secondaryColor, onDownload: downloadAction, onRemoveDownload: removeAction, isDownloading: isDownloading, onRemoveFromPlaylist: onContextRemove.map { remove in { remove(index) } }, onAddToPlaylist: onAddToPlaylist)
            .contentShape(Rectangle())
            .onTapGesture { onTap(index) }
            .listRowBackground(Color.clear)
    }
}
