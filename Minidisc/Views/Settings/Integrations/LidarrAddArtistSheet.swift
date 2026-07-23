// Minidisc — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import OSLog

/// Confirms the options for adding an artist to Lidarr (root folder, profiles, monitoring), then adds it.
struct LidarrAddArtistSheet: View {
    let artist: LidarrArtistLookup
    let client: LidarrClient
    /// Called on a successful add, so the parent can close the search and show a toast.
    let onAdded: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var rootFolders: [LidarrRootFolder] = []
    @State private var qualityProfiles: [LidarrProfile] = []
    @State private var metadataProfiles: [LidarrProfile] = []

    @State private var selectedRootFolder: Int?
    @State private var selectedQuality: Int?
    @State private var selectedMetadata: Int?
    @State private var monitor: LidarrMonitorOption = .all
    @State private var searchOnAdd = true

    @State private var isLoading = true
    @State private var isAdding = false
    @State private var errorMessage: String?

    private var canAdd: Bool {
        selectedRootFolder != nil && selectedQuality != nil && selectedMetadata != nil && !isAdding
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: MinidiscSpacing.m) {
                        poster
                        VStack(alignment: .leading, spacing: 2) {
                            Text(artist.artistName).font(.minidiscCellTitle).lineLimit(2)
                            if let disambiguation = artist.disambiguation, !disambiguation.isEmpty {
                                Text(disambiguation).font(.minidiscCaption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }

                if isLoading {
                    Section { HStack { Spacer(); ProgressView(); Spacer() } }
                } else {
                    Section {
                        Picker("Root Folder", selection: $selectedRootFolder) {
                            ForEach(rootFolders) { folder in
                                Text(folder.path).tag(Int?.some(folder.id))
                            }
                        }
                        Picker("Quality Profile", selection: $selectedQuality) {
                            ForEach(qualityProfiles) { profile in
                                Text(profile.name).tag(Int?.some(profile.id))
                            }
                        }
                        Picker("Metadata Profile", selection: $selectedMetadata) {
                            ForEach(metadataProfiles) { profile in
                                Text(profile.name).tag(Int?.some(profile.id))
                            }
                        }
                        Picker("Monitor", selection: $monitor) {
                            ForEach(LidarrMonitorOption.allCases) { option in
                                Text(option.displayName).tag(option)
                            }
                        }
                        Toggle("Search for missing albums", isOn: $searchOnAdd)
                            .tint(Color(.systemGreen))
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.minidiscCaption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Add Artist")
            .navigationBarTitleDisplayModeInline()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await add() }
                    } label: {
                        if isAdding { ProgressView() } else { Text("Add") }
                    }
                    .disabled(!canAdd)
                }
            }
            .task { await loadOptions() }
        }
    }

    @ViewBuilder
    private var poster: some View {
        AsyncImage(url: artist.posterURL) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            RoundedRectangle(cornerRadius: MinidiscCornerRadius.standard)
                .fill(Color.secondary.opacity(0.15))
                .overlay { Image(systemName: "music.mic").foregroundStyle(.secondary) }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: MinidiscCornerRadius.standard))
    }

    private func loadOptions() async {
        do {
            async let folders = client.rootFolders()
            async let quality = client.qualityProfiles()
            async let metadata = client.metadataProfiles()
            let (f, q, m) = try await (folders, quality, metadata)
            rootFolders = f
            qualityProfiles = q
            metadataProfiles = m
            selectedRootFolder = f.first?.id
            selectedQuality = q.first?.id
            selectedMetadata = m.first?.id
        } catch {
            errorMessage = friendlyMessage(error)
        }
        isLoading = false
    }

    private func add() async {
        guard let rootId = selectedRootFolder,
              let root = rootFolders.first(where: { $0.id == rootId }),
              let qualityId = selectedQuality,
              let metadataId = selectedMetadata else { return }
        isAdding = true
        errorMessage = nil
        defer { isAdding = false }

        let request = LidarrAddArtistRequest(
            artist: artist,
            qualityProfileId: qualityId,
            metadataProfileId: metadataId,
            rootFolderPath: root.path,
            monitor: monitor,
            searchForMissingAlbums: searchOnAdd
        )
        do {
            try await client.addArtist(request)
            onAdded()
            dismiss()
        } catch {
            errorMessage = friendlyMessage(error)
        }
    }

    private func friendlyMessage(_ error: Error) -> String {
        guard let lidarr = error as? LidarrError else { return error.localizedDescription }
        switch lidarr {
        case .unauthorized: return String(localized: "The API key was rejected.")
        case .htmlResponse: return String(localized: "A reverse proxy is blocking the request.")
        case .cancelled: return String(localized: "The request was cancelled.")
        case .badURL: return String(localized: "The Lidarr address is not valid.")
        case .transport(let detail), .decoding(let detail): return detail
        }
    }
}
