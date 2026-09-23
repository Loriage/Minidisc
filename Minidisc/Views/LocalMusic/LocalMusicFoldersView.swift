import SwiftUI
import UniformTypeIdentifiers

struct LocalMusicFoldersView: View {
    @Environment(\.appContainer) private var container
    @State private var choosingFolder = false

    var body: some View {
        Form {
            if let library = container?.localMusic {
                Section {
                    ForEach(library.snapshot.folders) { folder in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(folder.name, systemImage: "folder")
                            if !folder.isAccessible {
                                Text("Folder unavailable. Add it again to restore access.", tableName: "LocalMusic")
                                    .font(.caption).foregroundStyle(.secondary)
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
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your files stay in place. Removing a folder from Minidisc does not delete them.", tableName: "LocalMusic")
                        Text("Download cloud files in Files before playing them.", tableName: "LocalMusic")
                    }
                }
                if library.isRefreshing {
                    Section { ProgressView() }
                }
                if let error = library.errorMessage {
                    Section { Text(error).foregroundStyle(.secondary) }
                }
            }
        }
        .navigationTitle(Text("Music Folders", tableName: "LocalMusic"))
        .modifier(LocalMusicFolderPicker(isPresented: $choosingFolder))
    }
}

private struct LocalMusicFolderPicker: ViewModifier {
    @Binding var isPresented: Bool
    @Environment(\.appContainer) private var container
    @State private var errorMessage: String?

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $isPresented, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    Task {
                        container?.localMusic.errorMessage = nil
                        await container?.localMusic.add(urls)
                        errorMessage = container?.localMusic.errorMessage
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
