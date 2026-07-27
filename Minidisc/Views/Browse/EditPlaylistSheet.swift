import SwiftUI
import OSLog
import UniformTypeIdentifiers

struct EditPlaylistSheet: View {
    let playlistId: String
    let serverId: UUID
    let currentName: String
    let currentComment: String
    let currentCoverArtId: String?
    let songs: [DisplayableSong]
    var onCommitted: () -> Void = {}
    var onDeleted: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appContainer) private var container
    @Environment(DominantColorExtractor.self) private var colorExtractor

    @State private var editName: String = ""
    @State private var editComment: String = ""
    @State private var editSongs: [DisplayableSong] = []
    @State private var selectedSongIds: Set<String> = []
    @State private var selectedGradient: PlaylistGradientShape?
    @State private var photoIsCover = false
    @State private var coverDirty = false
    @State private var isSaving = false
    @State private var showDeleteConfirm = false
    @State private var showAddMusic = false
    @State private var loaded = false

    @State private var pendingImage: UIImage?
    @State private var showImageOptions = false
    @State private var showImagePicker = false
    @State private var showCamera = false
    @State private var showFilePicker = false
    @State private var imageToCrop: CroppableImage?

    var body: some View {
        NavigationStack {
            List(selection: $selectedSongIds) {
                Section {
                    coverCarousel
                        .listRowInsets(EdgeInsets(top: MinidiscSpacing.s, leading: 0, bottom: MinidiscSpacing.s, trailing: 0))
                        .listRowSeparator(.hidden)
                }

                Section {
                    TextField("Playlist Title", text: $editName)
                        .font(.system(.title2, design: .rounded, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .padding(.vertical, MinidiscSpacing.xs)
                    TextField("Description", text: $editComment, axis: .vertical)
                        .multilineTextAlignment(.center)
                        .lineLimit(1...4)
                }
                .listRowSeparator(.hidden)

                Section {
                    ForEach(editSongs) { song in
                        trackRow(song)
                            .tag(song.id)
                    }
                    .onMove { from, to in
                        editSongs.move(fromOffsets: from, toOffset: to)
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Edit Playlist")
            .navigationBarTitleDisplayModeInline()
            .environment(\.editMode, .constant(.active))
            .toolbar { toolbar }
            .sheet(isPresented: $showAddMusic) {
                if let c = container {
                    AddMusicSheet(
                        playlistName: currentName,
                        existingTrackIds: editSongs.map(\.id)
                    ) { added in
                        editSongs.append(contentsOf: added)
                    }
                    .environment(colorExtractor)
                    .environment(c.artworkImageCache)
                    .environment(\.appContainer, c)
                }
            }
            .confirmationDialog("Delete \"\(currentName)\"?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { Task { await deletePlaylist() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes the playlist everywhere, including any downloaded copy.")
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
            .task {
                guard !loaded else { return }
                loaded = true
                editName = currentName
                editComment = currentComment
                editSongs = songs
                loadCurrentChoice()
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button { dismiss() } label: { CircleToolbarLabel(systemName: "xmark") }
                .buttonStyle(.plain)
                .disabled(isSaving)
        }
        ToolbarItem(placement: .confirmationAction) {
            if isSaving {
                ProgressView().controlSize(.small)
            } else {
                let canSave = !editName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                Button { Task { await commit() } } label: { CircleToolbarLabel(systemName: "checkmark", filled: canSave) }
                    .buttonStyle(.plain)
                    .disabled(!canSave)
            }
        }
        ToolbarItemGroup(placement: .bottomBar) {
            Button(role: .destructive) { showDeleteConfirm = true } label: {
                Image(systemName: "trash")
            }
            .disabled(isSaving)
            Spacer()
            if selectedSongIds.isEmpty {
                Button { showAddMusic = true } label: { Image(systemName: "plus") }
                    .disabled(isSaving || container?.serverState.isOnline != true)
            } else {
                Button(role: .destructive) { removeSelectedTracks() } label: {
                    Text("Remove \(selectedSongIds.count)")
                }
                .disabled(isSaving)
            }
        }
    }

    private func trackRow(_ song: DisplayableSong) -> some View {
        HStack(spacing: MinidiscSpacing.m) {
            CoverArtView(id: song.coverArtId ?? song.id, size: 80, cornerRadius: MinidiscCornerRadius.standard)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title).font(.minidiscCellTitle).lineLimit(1)
                if let artist = song.artist {
                    Text(artist).font(.minidiscCellSubtitle).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }

    private func removeSelectedTracks() {
        editSongs.removeAll { selectedSongIds.contains($0.id) }
        selectedSongIds.removeAll()
    }

    private var coverCarousel: some View {
        PlaylistCoverCarousel(
            title: editName,
            selectedGradient: selectedGradient,
            isPhotoSelected: photoIsCover,
            photoPreview: photoPreviewImage,
            showsPhotoOption: showsPhotoOption,
            leadingLabel: "Current",
            leadingCoverArtId: currentCoverArtId ?? playlistId,
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

    // MARK: - State

    private var hasPhoto: Bool {
        return pendingImage != nil
    }
    private var showsPhotoOption: Bool {
        return true
    }
    private var photoPreviewImage: PlatformImage? {
        return pendingImage
    }

    /// Defer presenting the crop screen so the picker fully dismisses first (sequential full-screen covers).
    private func presentCrop(_ image: UIImage) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            imageToCrop = CroppableImage(image: image)
        }
    }

    private func loadCurrentChoice() {
        guard let c = container else { return }
        if let choice = PlaylistCoverStore(modelContainer: c.modelContainer).choice(playlistId: playlistId, serverId: serverId),
           choice.isUserPicked, let spec = choice.spec {
            selectedGradient = spec.shape
        }
    }

    // MARK: - Commit / cover / delete

    private func commit() async {
        guard let c = container else { return }
        isSaving = true
        defer { isSaving = false }

        let trimmedName = editName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedComment = editComment.trimmingCharacters(in: .whitespacesAndNewlines)
        let commentChanged = trimmedComment != currentComment.trimmingCharacters(in: .whitespacesAndNewlines)
        let songsChanged = editSongs.map(\.id) != songs.map(\.id)

        if !trimmedName.isEmpty && trimmedName != currentName.trimmingCharacters(in: .whitespacesAndNewlines) {
            try? await c.playlistService.renamePlaylist(id: playlistId, newName: trimmedName)
        }
        if songsChanged {
            try? await c.playlistService.reorderTracks(playlistId: playlistId, orderedSongIds: editSongs.map(\.id))
        }
        // Reordering drops the server-side description, so restore it after the replace.
        if (songsChanged && !trimmedComment.isEmpty) || commentChanged {
            try? await c.playlistService.updateDescription(id: playlistId, description: trimmedComment)
        }
        if coverDirty {
            await applyCover(container: c)
        }
        await AddMusicCommitter.deriveFirstTrackCoverIfNeeded(
            wasEmpty: songs.isEmpty,
            firstSong: editSongs.first,
            playlistId: playlistId,
            serverId: serverId,
            container: c,
            colorExtractor: colorExtractor
        )
        dismiss()
        onCommitted()
    }

    private func applyCover(container c: AppContainer) async {
        let manager = PlaylistCoverManager(
            serverState: c.serverState,
            serverService: c.serverService,
            downloadService: c.downloadService,
            artworkImageCache: c.artworkImageCache
        )
        let store = PlaylistCoverStore(modelContainer: c.modelContainer)
        if let shape = selectedGradient {
            let spec = await PlaylistGradientResolver.resolve(
                form: shape,
                firstTrackCoverArtId: songs.first?.coverArtId,
                artworkImageCache: c.artworkImageCache,
                colorExtractor: colorExtractor
            )
            await manager.applyGradientCover(spec, playlistId: playlistId)
            store.save(spec, playlistId: playlistId, serverId: serverId, isUserPicked: true)
            return
        }
        if photoIsCover, let image = pendingImage, let data = image.jpegData(compressionQuality: 0.85) {
            await manager.applyImageCover(data, playlistId: playlistId)
            store.remove(playlistId: playlistId, serverId: serverId)
        }
        // Leading "Current" with no photo → no cover change (no cover-delete API exists).
    }

    private func deletePlaylist() async {
        guard let c = container else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await c.playlistService.deletePlaylist(id: playlistId, purgeDownloads: true)
            dismiss()
            onDeleted()
        } catch {
            Logger.playlist.error("EditPlaylistSheet: delete failed: \(error)")
            c.toastService.showError("Failed to delete playlist")
        }
    }
}
