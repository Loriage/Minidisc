// Minidisc — Music client for Subsonic/OpenSubsonic servers
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// Manual import for a stuck download: lists the files Lidarr found with the artist, album, and tracks
/// it guessed, and imports the selected ones. Mirrors Lidarr's "Manual Import" dialog.
struct LidarrManualImportView: View {
    let downloadId: String
    let navigationTitle: String
    let client: LidarrClient

    @Environment(\.appContainer) private var container
    @Environment(\.dismiss) private var dismiss

    @State private var files: [LidarrManualImportFile] = []
    @State private var selected: Set<Int> = []
    @State private var isLoading = true
    @State private var isImporting = false
    @State private var errorMessage: String?

    private var importableSelected: [LidarrManualImportFile] {
        files.filter { selected.contains($0.id) && $0.isImportable }
    }

    var body: some View {
        Group {
            if isLoading {
                LoadingStateView()
            } else if let errorMessage {
                EmptyStateView(
                    systemImage: "exclamationmark.triangle",
                    title: "Couldn't Load Files",
                    subtitle: LocalizedStringKey(errorMessage),
                    action: .init(label: "Retry") { Task { await load() } }
                )
            } else if files.isEmpty {
                EmptyStateView(systemImage: "tray", title: "No Files", subtitle: "Lidarr found no files to import for this download.")
            } else {
                fileList
            }
        }
        .navigationTitle("Manual Import")
        .navigationBarTitleDisplayModeInline()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await runImport() }
                } label: {
                    if isImporting {
                        ProgressView()
                    } else {
                        Text("Import")
                    }
                }
                .disabled(importableSelected.isEmpty || isImporting)
            }
        }
        .task { await load() }
    }

    private var fileList: some View {
        List {
            Section {
                ForEach(files) { file in
                    Button {
                        toggle(file)
                    } label: {
                        LidarrManualImportRow(file: file, isSelected: selected.contains(file.id))
                    }
                    .buttonStyle(.plain)
                    .disabled(!file.isImportable)
                }
            } header: {
                Text(navigationTitle)
            } footer: {
                let count = importableSelected.count
                Text(count == 1 ? "1 file will be imported." : "\(count) files will be imported.")
            }
        }
        .listStyle(.insetGrouped)
    }

    private func toggle(_ file: LidarrManualImportFile) {
        guard file.isImportable else { return }
        if selected.contains(file.id) { selected.remove(file.id) } else { selected.insert(file.id) }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let fetched = try await client.manualImportCandidates(downloadId: downloadId)
            files = fetched
            selected = Set(fetched.filter(\.isImportable).map(\.id))
        } catch {
            if let lidarr = error as? LidarrError, case .cancelled = lidarr {} else {
                errorMessage = LidarrLibraryView.message(for: (error as? LidarrError) ?? .transport(error.localizedDescription))
            }
        }
        isLoading = false
    }

    private func runImport() async {
        let requests = importableSelected.compactMap(LidarrManualImportFileRequest.init(file:))
        guard !requests.isEmpty else { return }
        isImporting = true
        defer { isImporting = false }
        do {
            try await client.runManualImport(files: requests)
            NotificationCenter.default.post(name: .lidarrQueueDidChange, object: nil)
            container?.toastService.showSuccess(String(localized: "Import started in Lidarr"))
            dismiss()
        } catch {
            container?.toastService.showError(String(localized: "Couldn't start the import."))
        }
    }
}

// MARK: - Row

private struct LidarrManualImportRow: View {
    let file: LidarrManualImportFile
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: MinidiscSpacing.m) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isSelected ? Color.minidiscAccent : .secondary)
                .opacity(file.isImportable ? 1 : 0.35)

            VStack(alignment: .leading, spacing: 3) {
                Text(file.displayName)
                    .font(.minidiscCellTitle)
                    .lineLimit(2)

                if let artist = file.artist?.artistName, let album = file.album?.title {
                    Text("\(artist) — \(album)")
                        .font(.minidiscCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: MinidiscSpacing.xs) {
                    if let quality = file.qualityName { Text(quality) }
                    let trackCount = file.tracks?.count ?? 0
                    if trackCount > 0 {
                        if file.qualityName != nil { Text("·") }
                        Text(trackCount == 1 ? "1 track" : "\(trackCount) tracks")
                    }
                }
                .font(.minidiscCaption)
                .foregroundStyle(.secondary)

                ForEach(file.reasons, id: \.self) { reason in
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .font(.minidiscCaption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, MinidiscSpacing.xs)
        .contentShape(Rectangle())
    }
}
