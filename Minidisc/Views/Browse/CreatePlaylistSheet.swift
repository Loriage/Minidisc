import SwiftUI
import SwiftSonic
import UniformTypeIdentifiers

struct CreatePlaylistSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appContainer) private var container
    @Environment(DominantColorExtractor.self) private var colorExtractor
    @State private var viewModel: CreatePlaylistViewModel?
    @State private var selectedGradient: PlaylistGradientShape?
    @State private var photoIsCover = false
    @State private var showAddMusic = false
    @State private var pendingSongs: [DisplayableSong] = []

    var onCreated: ((PlaylistWithSongs) -> Void)? = nil

    @State private var pendingImage: UIImage?
    @State private var showImageOptions = false
    @State private var showImagePicker = false
    @State private var showCamera = false
    @State private var showFilePicker = false
    @State private var imageToCrop: CroppableImage?

    var body: some View {
        NavigationStack {
            Group {
                if let vm = viewModel {
                    content(vm)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayModeInline()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .tint(.primary)
                        .disabled(viewModel?.isCreating == true)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if viewModel?.isCreating == true {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        let canCreate = viewModel?.canCreate ?? false
                        Button("Create Playlist", systemImage: "checkmark") {
                            guard let vm = viewModel, let c = container else { return }
                            Task {
                                if let created = await vm.create() {
                                    await applyCover(playlistId: created.id, title: created.name, coverArtId: created.coverArt, container: c)
                                    await addPendingSongs(playlistId: created.id, title: created.name, coverArtId: created.coverArt, container: c)
                                    onCreated?(created)
                                    dismiss()
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canCreate)
                    }
                }
            }
        }
        .confirmationDialog("Add Cover Art", isPresented: $showImageOptions, titleVisibility: .visible) {
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
            if pendingImage != nil {
                Button("Remove Image", role: .destructive) { pendingImage = nil }
            }
            Button("Cancel", role: .cancel) {}
        }
        .tint(.primary)
        .sheet(isPresented: $showAddMusic) {
            if let c = container {
                AddMusicSheet(
                    playlistName: addMusicPlaylistName,
                    existingTrackIds: pendingSongs.map(\.id)
                ) { added in
                    pendingSongs.append(contentsOf: added)
                }
                .environment(colorExtractor)
                .environment(c.artworkImageCache)
                .environment(\.appContainer, c)
            }
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
            SquareCropView(
                image: croppable.image,
                onCrop: { pendingImage = $0; imageToCrop = nil },
                onCancel: { imageToCrop = nil }
            )
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.jpeg, .png, .heic, .webP],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url), let img = UIImage(data: data) {
                presentCrop(img)
            }
        }
        .task {
            guard let c = container else { return }
            if viewModel == nil {
                viewModel = CreatePlaylistViewModel(
                    playlistService: c.playlistService,
                    toastService: c.toastService
                )
            }
        }
    }

    @ViewBuilder
    private func content(_ vm: CreatePlaylistViewModel) -> some View {
        ScrollView {
            VStack(spacing: MinidiscSpacing.xl) {
                TextField("Playlist Title", text: Bindable(vm).name)
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .submitLabel(.done)
                    .padding(.vertical, MinidiscSpacing.s)
                    .padding(.horizontal, MinidiscSpacing.l)

                coverCarousel(vm)

                selectedSongsList

                addSongsRow
            }
            .padding(.top, MinidiscSpacing.m)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder
    private var selectedSongsList: some View {
        if !pendingSongs.isEmpty {
            VStack(spacing: 0) {
                ForEach(pendingSongs) { song in
                    HStack(spacing: MinidiscSpacing.l) {
                        CoverArtView(id: song.coverArtId ?? song.id, size: 120, cornerRadius: MinidiscCornerRadius.standard)
                            .frame(width: 52, height: 52)
                            .minidiscCoverStyle(cornerRadius: MinidiscCornerRadius.standard)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(song.title)
                                .font(.minidiscCellTitle)
                                .lineLimit(1)
                            if let artist = song.artist {
                                Text(artist)
                                    .font(.minidiscCellSubtitle)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: MinidiscSpacing.s)
                        Button {
                            pendingSongs.removeAll { $0.id == song.id }
                        } label: {
                            Image(systemName: "minus.circle")
                                .font(.system(size: 18))
                                .foregroundStyle(Color.minidiscAccent)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(song.title)")
                    }
                    .padding(.vertical, MinidiscSpacing.xs)
                    if song.id != pendingSongs.last?.id {
                        Divider().padding(.leading, 68)
                    }
                }
            }
            .padding(.horizontal, MinidiscSpacing.l)
        }
    }

    private var addSongsRow: some View {
        Button {
            showAddMusic = true
        } label: {
            HStack(spacing: MinidiscSpacing.m) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.secondary.opacity(0.18))
                    .frame(width: 48, height: 48)
                    .overlay {
                        Image(systemName: "plus")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                Text("Add Songs")
                    .font(.minidiscCellTitle)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                if !pendingSongs.isEmpty {
                    Text("\(pendingSongs.count)")
                        .font(.minidiscCellSubtitle)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(container?.serverState.isOnline != true)
        .padding(.horizontal, MinidiscSpacing.l)
    }

    private var addMusicPlaylistName: String {
        let trimmed = (viewModel?.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(localized: "New Playlist") : trimmed
    }

    private var hasPhoto: Bool {
        return pendingImage != nil
    }

    private var showsPhotoOption: Bool {
        return true
    }

    private var photoPreviewImage: PlatformImage? {
        return pendingImage
    }

    private func presentCrop(_ image: UIImage) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            imageToCrop = CroppableImage(image: image)
        }
    }

    private func coverCarousel(_ vm: CreatePlaylistViewModel) -> some View {
        PlaylistCoverCarousel(
            title: vm.name,
            selectedGradient: selectedGradient,
            isPhotoSelected: photoIsCover,
            photoPreview: photoPreviewImage,
            showsPhotoOption: showsPhotoOption,
            leadingLabel: "None",
            onSelectLeading: {
                selectedGradient = nil
                photoIsCover = false
            },
            onSelectPhoto: {
                selectedGradient = nil
                photoIsCover = true
            },
            onRequestPhotoPicker: {
                selectedGradient = nil
                photoIsCover = true
                showImageOptions = true
            },
            onSelectGradient: { shape in
                selectedGradient = shape
                photoIsCover = false
            },
            cardFraction: 0.5
        )
    }

    private func applyCover(playlistId: String, title: String, coverArtId: String?, container c: AppContainer) async {
        let manager = PlaylistCoverManager(
            downloadService: c.downloadService,
            artworkImageCache: c.artworkImageCache
        )
        if let shape = selectedGradient {
            let spec = PlaylistGradientSpec.neutral(shape: shape)
            await manager.applyGradientCover(spec, playlistId: playlistId, title: title, coverArtId: coverArtId)
            if let serverId = c.serverState.activeServer?.id {
                PlaylistCoverStore(modelContainer: c.modelContainer)
                    .save(spec, playlistId: playlistId, serverId: serverId, isUserPicked: true)
            }
            return
        }
        if photoIsCover, let image = pendingImage, let data = image.jpegData(compressionQuality: 0.85) {
            await manager.applyImageCover(data, playlistId: playlistId, coverArtId: coverArtId)
        }
    }

    private func addPendingSongs(playlistId: String, title: String, coverArtId: String?, container c: AppContainer) async {
        guard !pendingSongs.isEmpty, let serverId = c.serverState.activeServer?.id else { return }
        await AddMusicCommitter.commit(
            addedSongs: pendingSongs,
            playlistId: playlistId,
            playlistName: title,
            coverArtId: coverArtId,
            serverId: serverId,
            existingTrackIds: [],
            currentComment: "",
            container: c,
            colorExtractor: colorExtractor
        )
    }
}
