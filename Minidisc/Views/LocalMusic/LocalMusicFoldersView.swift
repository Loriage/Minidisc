import SwiftUI
import UniformTypeIdentifiers

struct LocalMusicFoldersView: View {
    var isOnboarding = false
    @Environment(\.appContainer) private var container
    @State private var choosingFolder = false

    var body: some View {
        Form {
            if let library = container?.localMusic {
                Section {
                    Label { Text("Your Music, on This Device", tableName: "LocalMusic") } icon: {
                        Image(systemName: "music.note.house")
                    }
                    .font(.headline)
                    Text("Choose a music folder in Files. Minidisc finds songs in its subfolders and organizes them into albums and artists. No server is needed.", tableName: "LocalMusic")
                        .foregroundStyle(.secondary)
                }
                Section {
                    ForEach(library.snapshot.folders) { folder in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(folder.name, systemImage: "folder")
                            let tracks = library.snapshot.tracks.filter { $0.song.localFile?.folderID == folder.id }
                            Text("\(tracks.count) songs · \(tracks.filter(\.isAvailable).count) available", tableName: "LocalMusic")
                                .font(.caption).foregroundStyle(.secondary)
                            if !folder.isAccessible {
                                Text("Folder unavailable. Add it again to restore access.", tableName: "LocalMusic")
                                    .font(.caption).foregroundStyle(.secondary)
                                Button { choosingFolder = true } label: {
                                    Text("Restore Access", tableName: "LocalMusic")
                                }
                                .disabled(library.isRefreshing)
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                Task {
                                    if container?.playerState.currentTrack?.localFile?.folderID == folder.id {
                                        await container?.playerService.stop()
                                    }
                                    await library.remove(folder)
                                }
                            } label: { Text("Remove Folder", tableName: "LocalMusic") }
                            .disabled(library.isRefreshing)
                        }
                    }
                    Button { choosingFolder = true } label: {
                        Label { Text("Add Folder", tableName: "LocalMusic") } icon: { Image(systemName: "folder.badge.plus") }
                    }
                    .disabled(library.isRefreshing)
                    .accessibilityIdentifier("localMusic.addFolder")
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your files stay in place. Removing a folder from Minidisc does not delete them.", tableName: "LocalMusic")
                        Text("Download cloud files in Files before playing them.", tableName: "LocalMusic")
                    }
                }
                if library.isRefreshing {
                    Section {
                        ProgressView { Text("Updating Your Music…", tableName: "LocalMusic") }
                    }
                } else if !library.snapshot.folders.isEmpty {
                    Section {
                        Button {
                            Task { await library.refresh() }
                        } label: {
                            Label { Text("Refresh Music", tableName: "LocalMusic") } icon: { Image(systemName: "arrow.clockwise") }
                        }
                    } footer: {
                        Text("Changes in your folders are checked while Minidisc is open. You can also refresh after adding music in Files.", tableName: "LocalMusic")
                    }
                }
                if let error = library.errorMessage {
                    Section { Text(error).foregroundStyle(.secondary) }
                }
            }
        }
        .scrollContentBackground(isOnboarding ? .hidden : .visible)
        .background(isOnboarding ? MinidiscColors.backgroundPrimary : Color(uiColor: .systemGroupedBackground))
        .tint(isOnboarding ? MinidiscColors.accent : .minidiscAccent)
        .navigationTitle(Text("Music Folders", tableName: "LocalMusic"))
        .modifier(LocalMusicFolderPicker(isPresented: $choosingFolder))
    }
}

struct LocalMusicFolderPicker: ViewModifier {
    @Binding var isPresented: Bool
    @Environment(\.appContainer) private var container
    @State private var errorMessage: String?
    @AppStorage("onboardingComplete") private var onboardingComplete = false
    @AppStorage("minidisc.localMusicEnabled") private var localMusicEnabled = false

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $isPresented, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    Task {
                        container?.localMusic.errorMessage = nil
                        await container?.localMusic.add(urls)
                        errorMessage = container?.localMusic.errorMessage
                        if onboardingComplete, container?.localMusic.snapshot.folders.isEmpty == false {
                            localMusicEnabled = true
                        }
                    }
                case .failure:
                    errorMessage = LocalMusicError.folderAccess.localizedDescription
                }
            }
            .alert(Text("Local Files", tableName: "LocalMusic"), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
    }
}
