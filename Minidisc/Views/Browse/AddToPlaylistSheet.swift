import SwiftUI
import SwiftSonic

struct AddToPlaylistSheet: View {
    let request: PlaylistAdditionRequest
    var onAdded: (() -> Void)? = nil
    @Environment(\.appContainer) private var container
    @Environment(\.dismiss) private var dismiss
    @State private var vm: AddToPlaylistViewModel?
    @State private var searchText = ""
    @State private var showCreate = false
    @State private var pendingDuplicate: Playlist?

    var body: some View {
        NavigationStack {
            Group {
                if let vm {
                    PlaylistDestinationsList(vm: vm, query: searchText, onCreate: { showCreate = true }) { playlist in
                        Task {
                            switch await vm.checkAndAdd(to: playlist) {
                            case .added: finish()
                            case .duplicate: pendingDuplicate = playlist
                            case .failed: break
                            }
                        }
                    }
                } else { ProgressView() }
            }
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayModeInline()
            .searchable(text: $searchText, prompt: "Find a playlist")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(vm?.isSaving == true)
                }
            }
            .navigationDestination(isPresented: $showCreate) {
                if let vm { NewPlaylistDestinationForm(vm: vm, onSaved: finish) }
            }
        }
        .interactiveDismissDisabled(vm?.isSaving == true)
        .task {
            guard vm == nil, let container else { return }
            let model = AddToPlaylistViewModel(songs: request.songs, playlistService: container.playlistService,
                toastService: container.toastService,
                recents: RecentPlaylistDestinations(serverID: container.serverState.activeServer?.id.uuidString ?? ""))
            vm = model
            showCreate = request.createsPlaylist
            await model.load()
        }
        .confirmationDialog("Already in Playlist", isPresented: Binding(
            get: { pendingDuplicate != nil }, set: { if !$0 { pendingDuplicate = nil } }
        ), titleVisibility: .visible, presenting: pendingDuplicate) { playlist in
            Button("Add Only New Songs") { add(to: playlist, skippingDuplicates: true) }
            Button("Add Anyway") { add(to: playlist, skippingDuplicates: false) }
            Button("Cancel", role: .cancel) { pendingDuplicate = nil }
        } message: { _ in
            Text("Some selected songs are already in this playlist.")
        }
        .tint(.primary)
    }

    private func finish() {
        dismiss()
        onAdded?()
    }

    private func add(to playlist: Playlist, skippingDuplicates: Bool) {
        pendingDuplicate = nil
        Task { if await vm?.forceAdd(to: playlist, skippingDuplicates: skippingDuplicates) == true { finish() } }
    }
}

private struct PlaylistDestinationsList: View {
    let vm: AddToPlaylistViewModel
    let query: String
    let onCreate: () -> Void
    let onSelect: (Playlist) -> Void

    var body: some View {
        List {
            Section {
                Button("New Playlist", systemImage: "plus.circle", action: onCreate)
                    .foregroundStyle(Color.minidiscAccent)
                    .accessibilityIdentifier("playlist.destination.new")
            } footer: {
                Text("\(vm.songs.count) songs selected")
            }
            if let error = vm.error {
                Section {
                    Text(error.displayMessage).font(.subheadline)
                    if vm.playlists.isEmpty { Button("Retry") { Task { await vm.load() } } }
                    else { Text("Your selection is kept. Tap the playlist to try again.").font(.subheadline).foregroundStyle(.secondary) }
                }
            }
            if vm.isLoading && vm.playlists.isEmpty { ProgressView() }
            let recent = vm.destinations(query: query, recent: true)
            let other = vm.destinations(query: query, recent: false)
            if !recent.isEmpty {
                Section("Recent Playlists") {
                    ForEach(recent) { playlist in destination(playlist) }
                }
            }
            if !other.isEmpty {
                Section("Playlists") {
                    ForEach(other) { playlist in destination(playlist) }
                }
            }
            if recent.isEmpty && other.isEmpty && !vm.isLoading && vm.error == nil {
                Text(query.isEmpty ? LocalizedStringResource("No playlists yet. Create one above.") : LocalizedStringResource("No matching playlists"))
                    .foregroundStyle(.secondary)
            }
        }
        .minidiscSheetListStyle()
        .disabled(vm.isSaving)
        .refreshable { await vm.load() }
    }

    private func destination(_ playlist: Playlist) -> some View {
        Button { onSelect(playlist) } label: {
            HStack(spacing: MinidiscSpacing.m) {
                PlaylistCoverThumbnail(playlistId: playlist.id, serverId: nil,
                    coverArtId: playlist.coverArt ?? playlist.id, title: playlist.name, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.name).font(.minidiscCellTitle).lineLimit(2)
                    Text("\(playlist.songCount) tracks").font(.minidiscCaption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if vm.addingToPlaylistIds.contains(playlist.id) { ProgressView() }
            }
            .padding(.vertical, MinidiscSpacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("playlist.destination.\(playlist.id)")
    }
}

private struct NewPlaylistDestinationForm: View {
    @Bindable var vm: AddToPlaylistViewModel
    let onSaved: () -> Void

    var body: some View {
        Form {
            Section {
                TextField("Playlist Title", text: $vm.newPlaylistName)
                    .disabled(vm.createdPlaylist != nil || vm.isSaving)
                    .accessibilityIdentifier("playlist.new.name")
            } footer: { Text("\(vm.songs.count) songs selected") }
            if let error = vm.error {
                Section {
                    Text(error.displayMessage)
                    if vm.createdPlaylist != nil {
                        Text("The playlist was created. Retry to finish adding your songs.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Button {
                    Task { if await vm.createAndAdd() { onSaved() } }
                } label: {
                    if vm.isSaving { ProgressView() }
                    else { Text(vm.createdPlaylist == nil ? LocalizedStringResource("Create Playlist") : LocalizedStringResource("Retry")) }
                }
                .disabled(!vm.canCreate)
                .accessibilityIdentifier("playlist.new.save")
            }
        }
        .navigationTitle("New Playlist")
        .navigationBarTitleDisplayModeInline()
        .navigationBarBackButtonHidden(vm.isSaving)
    }
}
